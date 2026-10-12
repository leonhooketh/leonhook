// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RouletteHookEth} from "../src/RouletteHookEth.sol";
import {RouletteInitializerEth} from "../src/RouletteInitializerEth.sol";
import {RouletteTokenEth as RouletteToken} from "../src/RouletteTokenEth.sol";

/// Запуск в Ethereum так, как его проведёт фабрика Programmable: initializer, токен (весь supply
/// у initializer), хук, затем initialize(hook, startTick). Поверх — торговля и розыгрыши.
contract RouletteLaunchEthForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant START_TICK = 200_280; // ≈ 2 ETH FDV (как в launch.eth.json)

    RouletteInitializerEth init;
    RouletteToken token;
    RouletteHookEth hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address dev = makeAddr("dev");
    address keeper = makeAddr("keeper");
    address trader = makeAddr("trader");
    bytes32[] chain;
    uint256 nextSecret = 1;

    function setUp() public {
        vm.createSelectFork("ethereum");
        assertEq(block.chainid, 1);

        uint256 len = 200;
        chain = new bytes32[](len + 1);
        chain[len] = keccak256("launch test seed");
        for (uint256 i = len; i > 0; i--) {
            chain[i - 1] = keccak256(abi.encode(chain[i]));
        }

        init = new RouletteInitializerEth(MANAGER);
        token = new RouletteToken("TEST", "TEST", SUPPLY, address(init), address(MANAGER));
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo(
            "RouletteHookEth.sol:RouletteHookEth",
            abi.encode(MANAGER, address(token), address(init), dev, keeper, chain[0], 0.0033 ether),
            hookAddr
        );
        hook = RouletteHookEth(hookAddr);
        key = hook.poolKey();

        init.initialize(address(hook), START_TICK);

        swapRouter = new PoolSwapTest(MANAGER);
        vm.deal(trader, 1_000 ether);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
    }

    // ───────────── helpers ─────────────

    function _swap(bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        vm.prank(trader);
        d = swapRouter.swap{value: value}(
            key,
            SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
    }

    function _buy(uint256 eth) internal returns (BalanceDelta) {
        return _swap(true, -int256(eth), eth);
    }

    function _fillEpoch() internal {
        for (uint256 i; i < 33; i++) {
            if (i % 2 == 0) _buy(0.05 ether);
            else _swap(false, -int256(token.balanceOf(trader) / 2), 0);
        }
    }

    function _setBlock(uint256 n) internal {
        vm.roll(n);
        for (uint256 x = n - 260; x < n; x++) {
            vm.setBlockhash(x, keccak256(abi.encode("block", x)));
        }
    }

    function _reveal() internal {
        _setBlock(hook.targetBlock() + 5);
        vm.prank(keeper);
        hook.reveal(chain[nextSecret++]);
    }

    // ───────────── запуск ─────────────

    function test_launchLocksWholeSupplyAtStartPrice() public view {
        assertTrue(init.launched());
        (uint160 sqrtP, int24 tick,,) = MANAGER.getSlot0(key.toId());
        assertEq(tick, START_TICK);
        assertEq(sqrtP, TickMath.getSqrtPriceAtTick(START_TICK));

        uint256 inPool = token.balanceOf(address(MANAGER));
        assertEq(token.balanceOf(address(init)), 0, "initializer keeps nothing");
        assertEq(inPool, token.totalSupply(), "everything that exists is in the pool");
        assertGt(inPool, SUPPLY - 1e9, "dust burned is negligible");

        bytes32 positionId = Position.calculatePositionKey(
            address(init), TickMath.minUsableTick(60), START_TICK, init.POSITION_SALT()
        );
        assertEq(MANAGER.getPositionLiquidity(key.toId(), positionId), init.lockedLiquidity());
        assertGt(init.lockedLiquidity(), 0);
    }

    function test_firstBuyPricesAtAboutTwoEthFdv() public {
        uint256 ethIn = 0.0001 ether;
        BalanceDelta d = _buy(ethIn);
        uint256 tokensOut = uint256(int256(d.amount1()));
        // 3,3% уходит хуку (3% проекта + 0,3% Programmable), в пул — 96,7%.
        uint256 fdvWei = SUPPLY * (ethIn * 967 / 1000) / tokensOut;
        assertApproxEqRel(fdvWei, 2.0062 ether, 0.002e18, "start FDV ~2.006 ETH");
    }

    function test_initializeRunsOnlyOnce() public {
        vm.expectRevert(RouletteInitializerEth.AlreadyLaunched.selector);
        init.initialize(address(hook), START_TICK);
    }

    function test_nobodyCanPullTheLiquidity() public {
        vm.expectRevert(RouletteInitializerEth.NotPoolManager.selector);
        init.unlockCallback(abi.encode(key, START_TICK));
    }

    function test_hookRejectsAnyOtherInitializer() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        MANAGER.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    // ───────────── торговля и розыгрыш на запущенном пуле ─────────────

    function test_roundsRunOnLaunchedPool() public {
        bool[4] memory seen;
        for (uint256 e; e < 60 && !(seen[0] && seen[1] && seen[2] && seen[3]); e++) {
            _fillEpoch();
            uint256 pot = hook.epochPot();
            uint256 supply = token.totalSupply();
            uint256 dip = hook.dipJar();
            uint256 donated = hook.totalToHolders();
            uint128 locked = hook.lockedLiquidity();
            _reveal();
            assertEq(hook.epochPot(), 0);
            if (token.totalSupply() < supply) seen[0] = true;
            else if (hook.dipJar() == dip + pot) seen[1] = true;
            else if (hook.totalToHolders() == donated + pot) seen[2] = true;
            else if (hook.lockedLiquidity() > locked) seen[3] = true;
            else revert("no outcome effect");
        }
        assertTrue(seen[0] && seen[1] && seen[2] && seen[3], "all four outcomes ran");
        uint256 accounted = hook.burnJar() + hook.dipJar() + hook.pendingPot() + hook.epochPot() + hook.devAccrued()
            + hook.fullRangeEth() + hook.platformAccrued();
        assertEq(MANAGER.balanceOf(address(hook), 0), accounted, "every wei of the hook's ETH is accounted for");
    }

    function test_smallSwapsPayButDoNotCount() public {
        _buy(0.003 ether);
        assertEq(hook.swapCount(), 0, "below 0.0033 ETH does not count");
        assertGt(hook.pendingPot(), 0, "but still pays into the pot");
        _buy(0.0034 ether);
        assertEq(hook.swapCount(), 1);
    }

    // ───────────── initial buy ─────────────

    function test_initialBuyIsBurnedAtLaunch() public {
        RouletteInitializerEth init2 = new RouletteInitializerEth(MANAGER);
        RouletteToken token2 = new RouletteToken("TEST", "TEST", SUPPLY, address(init2), address(MANAGER));
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x5555) << 144)
        );
        deployCodeTo(
            "RouletteHookEth.sol:RouletteHookEth",
            abi.encode(MANAGER, address(token2), address(init2), dev, keeper, chain[0], 0.0033 ether),
            hookAddr
        );
        RouletteHookEth hook2 = RouletteHookEth(hookAddr);

        vm.deal(address(this), 1 ether);
        uint256 initEthBefore = address(init2).balance; // на адресе форка могла лежать чужая пыль
        init2.initialize{value: 0.01 ether}(address(hook2), START_TICK);

        uint256 burned = init2.initialBuyBurned();
        assertEq(init2.initialBuyEth(), 0.01 ether);
        // 0.01 ETH минус 3% хуку при ~5e8 токенов за ETH на старте ≈ 4.85M токенов
        assertApproxEqRel(burned, 4_850_000 ether, 0.03e18, "about 0.485% of supply");
        assertEq(token2.balanceOf(address(init2)), 0, "initializer keeps no tokens");
        assertEq(address(init2).balance, initEthBefore, "the whole initial buy is spent");
        assertEq(token2.balanceOf(address(this)), 0, "launcher gets no tokens");
        assertLe(token2.totalSupply(), SUPPLY - burned, "bought tokens are gone");
        assertEq(token2.eligibleSupply(), 0, "nobody holds tokens yet");
        assertEq(hook2.swapCount(), 1, "the initial buy counts as the first swap");
        assertEq(hook2.devAccrued(), 0.0001 ether, "1% as on any swap");
        assertEq(hook2.platformAccrued(), 0.00003 ether, "0.3% for Programmable on the initial buy too");
        assertEq(hook2.pendingPot(), 0.0002 ether, "2% to the pot as on any swap");
    }
}

