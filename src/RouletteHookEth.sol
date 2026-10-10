// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IBurnable {
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

/// @title RouletteHookEth
/// @notice Пул ETH/TOKEN на Uniswap v4. С ETH-ноги каждого свапа: 2% в пот, 1% разработчику.
///         Каждые 33 свапа (от minSwapEth) раунд закрывается. Бот раскрывает секрет, и в той же
///         транзакции пот раунда целиком исполняет выпавший исход: Burn / Holder rewards / Full-range
///         срабатывают сразу, Dip buyback откладывает пот до просадки, которую выбирает бот.
/// @dev    Исход знает только тот, у кого секрет (бот), и он исполняется в момент раскрытия,
///         поэтому подготовиться под него заранее нельзя. Покупки идут по текущей цене пула.
///         Случайность: секрет hash chain + хеш блока Ethereum после закрытия раунда
///         (хеш включает RANDAO сети). Версия для Ethereum mainnet.
///         Любой сбой розыгрыша → пот в банку Burn.
///         Настроение: при закрытии раунда хук сравнивает среднюю цену засчитанных свапов с прошлым (±10%)
///         раундом и объём раунда со скользящим средним. Любимая муха настроения выпадает с шансом 55%,
///         остальные три — по 15%. Правила зашиты в код, менять их некому.
contract RouletteHookEth is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum Outcome {
        Burn,
        Dip,
        HolderRewards,
        FullRange
    }

    /// Calm → Holder rewards, Busy → Full-range, Hungry → Dip, Excited → Burn (жжёт, пока растёт).
    enum Mood {
        Calm,
        Busy,
        Hungry,
        Excited
    }

    // ───────────── Константы ─────────────

    uint256 public constant POT_BPS = 200; // 2% в пот
    uint256 public constant DEV_BPS = 100; // 1% разработчику
    uint256 public constant SWAPS_PER_EPOCH = 33;
    uint256 public constant FAVORED_PCT = 55; // шанс любимой мухи настроения; остальные делят 45% поровну
    // Тик пула = log(токенов за 1 ETH), поэтому цена токена растёт, когда тик падает.
    int256 public constant MOOD_UP_TICKS = 954; // цена токена +10% за раунд
    int256 public constant MOOD_DOWN_TICKS = 1054; // цена токена −10% за раунд
    uint256 public constant BUSY_VOLUME_X10 = 13; // объём раунда ≥ 1,3 × обычного
    uint256 public constant VOLUME_EMA_ROUNDS = 5; // «обычный» объём — скользящее среднее ~5 раундов
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;

    uint256 public constant TARGET_DELAY = 2; // блоков после закрытия раунда (~24 с)
    uint256 public constant BLOCKHASH_WINDOW = 256; // столько блоков помнит blockhash (~51 мин)
    uint256 public constant REVEAL_TIMEOUT = 1 hours;
    uint256 public constant DIP_MAX_IDLE = 24 hours;
    bytes32 public constant POSITION_SALT = keccak256("roulette.permanent.full-range.v1");

    uint256 internal constant ETH_ID = 0; // ERC6909 id нативного ETH в PoolManager
    uint8 internal constant OP_DEV = 4;
    uint8 internal constant JAR_BURN = 0;
    uint8 internal constant JAR_DIP = 1;

    // ───────────── Неизменяемые параметры ─────────────

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable initializer;
    address public immutable dev;
    uint256 public immutable minSwapEth;

    // ───────────── Состояние ─────────────

    address public owner; // может сменить цепочку секретов и адрес бота, но не трогает деньги
    address public keeper; // единственный, кто запускает исходы
    bool public initialized;
    PoolId public poolId;

    uint256 public devAccrued;

    uint256 public pendingPot; // открытый раунд
    uint256 public swapCount;

    uint256 public epochId; // последний закрытый раунд
    bool public awaiting;
    uint256 public epochPot;
    uint256 public targetBlock;
    bytes32 public targetHash;
    uint256 public snapshotAt;

    bytes32 public lastSecret; // hash chain: s[i-1] = keccak256(s[i])
    uint256 public revealCount;

    uint256 public burnJar; // поты после сбоя розыгрыша, недокупленные остатки, переливы из Dip
    uint256 public dipJar; // ждёт просадки
    uint256 public dipFundedAt;

    uint256 public fullRangeEth; // остатки после добавления full-range ликвидности (ERC6909)
    uint256 public fullRangeToken;
    uint128 public lockedLiquidity;
    uint256 public totalBurned;
    uint256 public totalToHolders; // ETH, начисленный холдерам через токен

    // Настроение. Счётчики накопительные с запуска (одна запись в упакованный слот на свап),
    // раунд = разница со снимком на его начало.
    int128 public cumTickSum; // сумма тиков после засчитанных свапов
    uint128 public cumVolume; // ETH-объём всех свапов пользователей
    int128 private _roundStartTickSum;
    uint128 private _roundStartVolume;
    int24 public lastAvgTick; // средний тик прошлого раунда (для первого — стартовый)
    uint256 public volumeEma;
    Mood public epochMood; // настроение последнего закрытого раунда

    bool private _executing;
    bytes32 private constant PENDING_ETH_SLOT = keccak256("roulette.pending-eth-amount"); // transient

    // ───────────── События и ошибки ─────────────

    event EpochClosed(uint256 indexed epochId, uint256 pot, uint256 targetBlock);
    event MoodSet(uint256 indexed epochId, Mood mood, int24 avgTick, int256 tickChange, uint256 volume, uint256 usualVolume);
    event HashSnapshotted(uint256 indexed epochId, bytes32 blockHash);
    event EpochResolved(uint256 indexed epochId, Outcome outcome, uint256 pot, bool fallbackUsed);
    event Executed(Outcome indexed outcome, uint256 ethSpent, uint256 tokensBurned, uint128 liquidityAdded);
    event Parked(uint8 indexed jar, uint256 amount);
    event DipRolledOver(uint256 amount);
    event DevClaimed(uint256 amount);
    event ChainHeadSet(bytes32 head);
    event KeeperSet(address keeper);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotPoolManager();
    error NotOwner();
    error NotKeeper();
    error InvalidConfiguration();
    error InvalidPool();
    error InvalidInitializer();
    error HookNotImplemented();
    error NotReady();
    error BadSecret();
    error Busy();
    error InvalidSettlement();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        IPoolManager manager,
        address token_,
        address initializer_,
        address dev_,
        address keeper_,
        bytes32 chainHead,
        uint256 minSwapEth_
    ) {
        if (
            address(manager) == address(0) || token_ == address(0) || initializer_ == address(0) || dev_ == address(0)
                || keeper_ == address(0) || chainHead == bytes32(0)
        ) revert InvalidConfiguration();

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        poolManager = manager;
        token = token_;
        initializer = initializer_;
        dev = dev_;
        minSwapEth = minSwapEth_;

        owner = dev_;
        keeper = keeper_;
        lastSecret = chainHead;
        emit OwnershipTransferred(address(0), dev_);
        emit KeeperSet(keeper_);
        emit ChainHeadSet(chainHead);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Единственный пул этого хука: нативный ETH / токен, LP-комиссия 0, шаг тиков 60.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), LP_FEE, TICK_SPACING, IHooks(address(this)));
    }

    // ═════════════════════════ Коллбэки PoolManager ═════════════════════════

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != initializer) revert InvalidInitializer();
        if (initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey().toId())) revert InvalidPool();
        initialized = true;
        poolId = key.toId();
        lastAvgTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyOurPool(key);
        // Собственные покупки хука не платят комиссию и не считаются.
        if (sender == address(this) || !_ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // ETH — указанная сумма: покупка с точным входом или продажа с точным выходом.
        uint256 amount = _abs(params.amountSpecified);
        uint256 fee = _collect(amount);
        // Засчитываем свап в afterSwap, когда цена пула уже после сделки.
        _stashEth(amount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _onlyOurPool(key);
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);
        if (_ethIsSpecified(params)) {
            _onUserSwap(_takeStashedEth()); // комиссия уже взята в beforeSwap
            return (IHooks.afterSwap.selector, 0);
        }
        // ETH — неуказанная сторона: покупка с точным выходом или продажа с точным входом.
        uint256 amount = _abs(delta.amount0());
        uint256 fee = _collect(amount);
        _onUserSwap(amount);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ═════════════════════════ Бот: розыгрыш и исход ═════════════════════════

    /// @notice Раскрыть следующий секрет и сразу исполнить выпавший исход на весь пот раунда.
    function reveal(bytes32 secret) external onlyKeeper {
        _poke();
        if (!awaiting || targetHash == bytes32(0)) revert NotReady();
        if (keccak256(abi.encode(secret)) != lastSecret) revert BadSecret();
        lastSecret = secret;
        revealCount++;

        Outcome o = outcomeFor(uint256(keccak256(abi.encode(secret, targetHash, epochId, address(this)))) % 100, epochMood);
        uint256 pot = epochPot;
        epochPot = 0;
        awaiting = false;
        emit EpochResolved(epochId, o, pot, false);
        if (pot == 0) return;

        if (o == Outcome.Dip) {
            if (dipJar == 0) dipFundedAt = block.timestamp;
            dipJar += pot;
            emit Parked(JAR_DIP, pot);
        } else {
            _run(uint8(o), pot, JAR_BURN);
        }
    }

    /// @notice Потратить банку Burn: купить токен по текущей цене и сжечь.
    function executeBurn(uint256 amount) external onlyKeeper {
        if (amount == 0 || amount > burnJar) revert NotReady();
        burnJar -= amount;
        _run(uint8(Outcome.Burn), amount, JAR_BURN);
    }

    /// @notice Бот увидел просадку: купить на банку Dip и сжечь.
    function executeDip(uint256 amount) external onlyKeeper {
        if (amount == 0 || amount > dipJar) revert NotReady();
        dipJar -= amount;
        if (dipJar == 0) dipFundedAt = 0;
        _run(uint8(Outcome.Burn), amount, JAR_DIP);
    }

    /// @notice Если просадки так и не случилось за сутки — банка Dip уходит в Burn.
    function rolloverDip() external onlyKeeper {
        uint256 amount = dipJar;
        if (amount == 0 || block.timestamp < dipFundedAt + DIP_MAX_IDLE) revert NotReady();
        dipJar = 0;
        dipFundedAt = 0;
        burnJar += amount;
        emit DipRolledOver(amount);
    }

    /// @notice Сохранить хеш целевого блока или применить фоллбек по таймауту.
    ///         Хук делает это и сам на каждом свапе.
    function poke() external onlyKeeper {
        _poke();
    }

    /// @notice Отправить накопленный 1% разработчику. Деньги могут уйти только на адрес dev.
    function claimDev() external {
        uint256 amount = devAccrued;
        if (amount == 0 || _executing) revert NotReady();
        devAccrued = 0;
        _executing = true;
        poolManager.unlock(abi.encode(OP_DEV, amount, uint8(0)));
        _executing = false;
        emit DevClaimed(amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_executing) revert NotReady();
        (uint8 op, uint256 amount, uint8 jar) = abi.decode(data, (uint8, uint256, uint8));
        poolManager.burn(address(this), ETH_ID, amount); // +amount ETH кредита

        if (op == OP_DEV) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, dev, amount);
            return "";
        }
        if (op == uint8(Outcome.HolderRewards)) {
            // ETH уходит на контракт токена, он сразу начисляет его холдерам (receive не ревертится).
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, token, amount);
            totalToHolders += amount;
            emit Executed(Outcome.HolderRewards, amount, 0, 0);
            return "";
        }
        if (poolManager.getLiquidity(poolId) == 0) {
            _park(jar, amount); // пул пуст — подождём
            return "";
        }

        PoolKey memory key = poolKey();
        if (op == uint8(Outcome.FullRange)) {
            (uint256 spent, uint256 bought) = _buy(key, amount / 2);
            uint128 added = _addFullRange(key, amount - spent, bought);
            emit Executed(Outcome.FullRange, amount, 0, added);
        } else {
            (uint256 spent, uint256 bought) = _buy(key, amount);
            if (amount > spent) _park(jar, amount - spent);
            if (bought != 0) {
                poolManager.take(Currency.wrap(token), address(this), bought);
                uint256 supplyBefore = IBurnable(token).totalSupply();
                IBurnable(token).burn(bought);
                if (IBurnable(token).totalSupply() != supplyBefore - bought) revert InvalidSettlement();
                totalBurned += bought;
            }
            emit Executed(Outcome.Burn, spent, bought, 0);
        }
        return "";
    }

    // ═════════════════════════ Админка ═════════════════════════
    // Владелец не может вывести деньги и поменять комиссии — только цепочку секретов и адрес бота.

    function setChainHead(bytes32 head) external {
        if (msg.sender != owner) revert NotOwner();
        if (awaiting) revert Busy();
        lastSecret = head;
        emit ChainHeadSet(head);
    }

    function setKeeper(address keeper_) external {
        if (msg.sender != owner) revert NotOwner();
        if (keeper_ == address(0)) revert InvalidConfiguration();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    // ═════════════════════════ Для бота / UI ═════════════════════════

    function status()
        external
        view
        returns (bool awaiting_, uint256 epochId_, uint256 targetBlock_, bytes32 targetHash_, uint256 revealCount_, uint256 currentBlock)
    {
        return (awaiting, epochId, targetBlock, targetHash, revealCount, block.number);
    }

    // ═════════════════════════ Внутреннее ═════════════════════════

    function _onlyOurPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    /// @dev currency0 — ETH. Указанная сторона — currency0, если (точный вход) == (zeroForOne).
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @dev Комиссия с ETH-суммы свапа: хранится как ERC6909-клеймы хука в PoolManager.
    function _collect(uint256 ethAmount) private returns (uint256 fee) {
        fee = ethAmount * (POT_BPS + DEV_BPS) / 10_000;
        if (fee == 0) return 0;
        poolManager.mint(address(this), ETH_ID, fee);
        uint256 devPart = fee * DEV_BPS / (POT_BPS + DEV_BPS);
        devAccrued += devPart;
        pendingPot += fee - devPart;
    }

    /// @dev Не должен ревертиться: любая ошибка здесь сломала бы все свапы пула.
    function _onUserSwap(uint256 ethAmount) private {
        int128 tick;
        if (ethAmount >= minSwapEth) {
            swapCount++;
            (, tick,,) = poolManager.getSlot0(poolId);
        }
        cumTickSum += tick;
        cumVolume += uint128(ethAmount);
        _poke();
        if (!awaiting && swapCount >= SWAPS_PER_EPOCH) _closeEpoch();
    }

    // ═════════════════════════ Настроение ═════════════════════════

    /// @notice Исход по броску 0..99 и настроению: 0–54 — любимая муха, дальше по 15 на каждую из трёх других.
    function outcomeFor(uint256 roll, Mood mood) public pure returns (Outcome) {
        Outcome fav = favoredOutcome(mood);
        if (roll < FAVORED_PCT) return fav;
        uint256 k = (roll - FAVORED_PCT) / ((100 - FAVORED_PCT) / 3); // 0, 1, 2
        return Outcome(k >= uint256(fav) ? k + 1 : k);
    }

    function favoredOutcome(Mood mood) public pure returns (Outcome) {
        if (mood == Mood.Excited) return Outcome.Burn;
        if (mood == Mood.Hungry) return Outcome.Dip;
        if (mood == Mood.Busy) return Outcome.FullRange;
        return Outcome.HolderRewards;
    }

    /// @notice ETH-объём открытого раунда.
    function roundVolume() public view returns (uint256) {
        return cumVolume - _roundStartVolume;
    }

    /// @dev Вызывается при закрытии раунда, swapCount ≥ 33. Не ревертится.
    function _setMood() private {
        int24 avg = int24(int256(cumTickSum - _roundStartTickSum) / int256(swapCount));
        int256 change = int256(avg) - int256(lastAvgTick);
        uint256 volume = roundVolume();
        uint256 usual = volumeEma;
        Mood m;
        if (change >= MOOD_DOWN_TICKS) m = Mood.Hungry;
        else if (change <= -MOOD_UP_TICKS) m = Mood.Excited;
        else if (usual != 0 && volume * 10 >= usual * BUSY_VOLUME_X10) m = Mood.Busy;
        else m = Mood.Calm;
        epochMood = m;
        emit MoodSet(epochId, m, avg, change, volume, usual);
        volumeEma = usual == 0 ? volume : (usual * (VOLUME_EMA_ROUNDS - 1) + volume) / VOLUME_EMA_ROUNDS;
        lastAvgTick = avg;
        _roundStartTickSum = cumTickSum;
        _roundStartVolume = cumVolume;
    }

    function _stashEth(uint256 amount) private {
        bytes32 slot = PENDING_ETH_SLOT;
        assembly ("memory-safe") {
            tstore(slot, amount)
        }
    }

    function _takeStashedEth() private returns (uint256 amount) {
        bytes32 slot = PENDING_ETH_SLOT;
        assembly ("memory-safe") {
            amount := tload(slot)
            tstore(slot, 0)
        }
    }

    function _closeEpoch() private {
        epochId++;
        awaiting = true;
        epochPot = pendingPot;
        pendingPot = 0;
        _setMood();
        swapCount = 0;
        targetBlock = block.number + TARGET_DELAY;
        targetHash = bytes32(0);
        snapshotAt = 0;
        emit EpochClosed(epochId, epochPot, targetBlock);
    }

    /// @dev Сохраняет хеш целевого блока, пока blockhash его помнит; иначе — фоллбек: пот в банку Burn.
    function _poke() private {
        if (!awaiting) return;
        if (targetHash == bytes32(0)) {
            uint256 n = block.number;
            if (n <= targetBlock) return;
            if (n - targetBlock <= BLOCKHASH_WINDOW) {
                bytes32 h = blockhash(targetBlock);
                if (h == bytes32(0)) return;
                targetHash = h;
                snapshotAt = block.timestamp;
                emit HashSnapshotted(epochId, h);
            } else {
                _fallback();
            }
        } else if (block.timestamp > snapshotAt + REVEAL_TIMEOUT) {
            _fallback();
        }
    }

    function _fallback() private {
        uint256 pot = epochPot;
        epochPot = 0;
        awaiting = false;
        burnJar += pot;
        emit EpochResolved(epochId, Outcome.Burn, pot, true);
    }

    function _run(uint8 op, uint256 amount, uint8 jar) private {
        _executing = true;
        poolManager.unlock(abi.encode(op, amount, jar));
        _executing = false;
    }

    function _park(uint8 jar, uint256 amount) private {
        poolManager.mint(address(this), ETH_ID, amount);
        if (jar == JAR_DIP) dipJar += amount;
        else burnJar += amount;
        emit Parked(jar, amount);
    }

    /// @dev Покупка токена за ETH с точным входом по текущей цене пула.
    function _buy(PoolKey memory key, uint256 amountIn) private returns (uint256 spent, uint256 bought) {
        if (amountIn == 0) return (0, 0);
        BalanceDelta d = poolManager.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        if (d.amount0() > 0 || d.amount1() < 0) revert InvalidSettlement();
        spent = uint256(-int256(d.amount0()));
        bought = uint256(int256(d.amount1()));
    }

    /// @dev Добавляет всё доступное (новое + остатки прошлых раз) как вечную позицию на весь диапазон.
    ///      Снять её невозможно: у хука нет функции удаления ликвидности.
    function _addFullRange(PoolKey memory key, uint256 ethIn, uint256 tokenIn) private returns (uint128 liquidity) {
        if (fullRangeEth != 0) poolManager.burn(address(this), ETH_ID, fullRangeEth);
        if (fullRangeToken != 0) poolManager.burn(address(this), uint160(token), fullRangeToken);
        uint256 eth = ethIn + fullRangeEth;
        uint256 tok = tokenIn + fullRangeToken;

        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        int24 low = TickMath.minUsableTick(TICK_SPACING);
        int24 high = TickMath.maxUsableTick(TICK_SPACING);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(low), TickMath.getSqrtPriceAtTick(high), eth, tok
        );

        int256 eth0 = int256(eth);
        int256 tok1 = int256(tok);
        if (liquidity != 0) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(low, high, int256(uint256(liquidity)), POSITION_SALT), ""
            );
            lockedLiquidity += liquidity;
            // d < 0 — потрачено на позицию; d может включать накопленные позицией LP-награды.
            eth0 += d.amount0();
            tok1 += d.amount1();
        }
        if (eth0 < 0 || tok1 < 0) revert InvalidSettlement();
        fullRangeEth = uint256(eth0);
        fullRangeToken = uint256(tok1);
        if (fullRangeEth != 0) poolManager.mint(address(this), ETH_ID, fullRangeEth);
        if (fullRangeToken != 0) poolManager.mint(address(this), uint160(token), fullRangeToken);
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ═════════════════════════ Неиспользуемые хуки ═════════════════════════

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
