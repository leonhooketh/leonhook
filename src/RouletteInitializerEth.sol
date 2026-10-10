// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IRouletteHookView {
    function poolKey() external view returns (PoolKey memory);
    function initializer() external view returns (address);
}

interface IBurnableToken {
    function burn(uint256 amount) external;
}

/// @title RouletteInitializerEth
/// @notice Запускает пул ETH/TOKEN одним вызовом в транзакции запуска: создаёт пул по стартовой цене
///         и кладёт весь supply односторонней позицией от минимальной цены до стартовой.
/// @dev    Позицию забрать нельзя: у контракта нет владельца и нет функции вывода, поэтому
///         ликвидность заблокирована навсегда. Пыль округления сжигается.
contract RouletteInitializerEth is IUnlockCallback {
    bytes32 public constant POSITION_SALT = keccak256("roulette.launch.locked-liquidity.v1");

    IPoolManager public immutable poolManager;

    bool public launched;
    uint128 public lockedLiquidity;
    int24 public startTick;

    event Launched(address indexed hook, int24 startTick, uint128 liquidity, uint256 tokensInPool, uint256 dustBurned);

    error AlreadyLaunched();
    error NotPoolManager();
    error WrongHook();
    error InvalidStartTick();
    error InvalidSettlement();

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    /// @notice Вызывается один раз фабрикой Programmable сразу после деплоя всех контрактов.
    /// @param hook        хук этого запуска (его initializer() должен указывать на этот контракт)
    /// @param startTick_  тик стартовой цены; кратен шагу тиков пула
    function initialize(address hook, int24 startTick_) external {
        if (launched) revert AlreadyLaunched();
        launched = true;

        PoolKey memory key = IRouletteHookView(hook).poolKey();
        if (
            IRouletteHookView(hook).initializer() != address(this) || address(key.hooks) != hook
                || Currency.unwrap(key.currency0) != address(0)
        ) revert WrongHook();
        if (
            startTick_ % key.tickSpacing != 0 || startTick_ <= TickMath.minUsableTick(key.tickSpacing)
                || startTick_ > TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidStartTick();

        startTick = startTick_;
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startTick_));
        poolManager.unlock(abi.encode(key, startTick_));

        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) IBurnableToken(address(token)).burn(dust);
        emit Launched(hook, startTick_, lockedLiquidity, token.balanceOf(address(poolManager)), dust);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, int24 upper) = abi.decode(data, (PoolKey, int24));
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        int24 lower = TickMath.minUsableTick(key.tickSpacing);

        // Цена стоит ровно на верхней границе позиции, поэтому позиция целиком в токене.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), token.balanceOf(address(this))
        );
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), POSITION_SALT), ""
        );
        if (delta.amount0() != 0 || delta.amount1() >= 0) revert InvalidSettlement();

        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), uint256(uint128(-delta.amount1())));
        poolManager.settle();
        lockedLiquidity = liquidity;
        return "";
    }
}
