// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {RouletteHookEth as RouletteHook} from "../src/RouletteHookEth.sol";
import {RouletteTokenEth as RouletteToken} from "../src/RouletteTokenEth.sol";

contract RouletteHookEthForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    RouletteToken token;
    RouletteHook hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address dev = makeAddr("dev");
    address keeper = makeAddr("keeper");
    address trader = makeAddr("trader");
    bytes32[] chain;
    uint256 nextSecret = 1;
    uint256 arbBlock;

    int24 constant START_TICK = 161_160; // ≈ 10M токенов за 1 ETH

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ethereum");
        assertEq(block.chainid, 1);
        arbBlock = block.number;
        _setArbBlock(arbBlock);

        uint256 len = 400;
        chain = new bytes32[](len + 1);
        chain[len] = keccak256("fork test seed");
        for (uint256 i = len; i > 0; i--) {
            chain[i - 1] = keccak256(abi.encode(chain[i]));
        }

        token = new RouletteToken("Roulette", "RLT", 1_000_000_000 ether, address(this), address(MANAGER));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        deployCodeTo(
            "RouletteHookEth.sol:RouletteHookEth",
            abi.encode(MANAGER, address(token), address(this), dev, keeper, chain[0], 0.001 ether),
            hookAddr
        );
        hook = RouletteHook(hookAddr);
        key = hook.poolKey();

        MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);
        token.approve(address(lpRouter), type(uint256).max);
        token.transfer(trader, 300_000_000 ether);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        vm.deal(trader, 1_000 ether);

        // Стартовая ликвидность: 10 ETH на весь диапазон.
        int24 low = TickMath.minUsableTick(60);
        int24 high = TickMath.maxUsableTick(60);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(START_TICK),
            TickMath.getSqrtPriceAtTick(low),
            TickMath.getSqrtPriceAtTick(high),
            10 ether,
            500_000_000 ether
        );
        vm.deal(address(this), 20 ether);
        lpRouter.modifyLiquidity{value: 11 ether}(key, ModifyLiquidityParams(low, high, int256(uint256(liq)), 0), "");
    }

    // ───────────── helpers ─────────────

    /// Переводит форк на блок n и задаёт хеши 260 предыдущих блоков (на форке будущих хешей нет).
    function _setArbBlock(uint256 n) internal {
        vm.roll(n);
        for (uint256 x = n > 260 ? n - 260 : 0; x < n; x++) {
            vm.setBlockhash(x, keccak256(abi.encode("block", x)));
        }
    }

    function _claims() internal view returns (uint256) {
        return MANAGER.balanceOf(address(hook), 0);
    }

    function _sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = MANAGER.getSlot0(key.toId());
    }

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

    function _sellTokens(uint256 amount) internal returns (BalanceDelta) {
        return _swap(false, -int256(amount), 0);
    }

    function _fillEpoch() internal {
        for (uint256 i; i < 33; i++) {
            if (i % 2 == 0) _buy(0.05 ether);
            else _sellTokens(400_000 ether);
        }
    }

    function _reveal() internal {
        arbBlock = hook.targetBlock() + 5;
        _setArbBlock(arbBlock);
        vm.prank(keeper);
        hook.reveal(chain[nextSecret++]);
    }

    function _accounted() internal view returns (uint256) {
        return hook.burnJar() + hook.dipJar() + hook.pendingPot() + hook.epochPot() + hook.devAccrued() + hook.fullRangeEth();
    }

    // ───────────── комиссии ─────────────

    function test_feeOnExactInputBuy() public {
        uint256 before = trader.balance;
        _buy(1 ether);
        assertEq(before - trader.balance, 1 ether, "trader pays exactly 1 ETH");
        assertEq(_claims(), 0.03 ether, "3% to hook");
        assertEq(hook.devAccrued(), 0.01 ether);
        assertEq(hook.pendingPot(), 0.02 ether);
    }

    function test_feeOnExactInputSell() public {
        BalanceDelta d = _sellTokens(10_000_000 ether);
        uint256 received = uint256(int256(d.amount0()));
        uint256 fee = _claims();
        assertGt(fee, 0);
        assertApproxEqAbs(fee, (received + fee) * 300 / 10_000, 1, "3% of pool output");
    }

    function test_feeOnExactOutputBuy() public {
        BalanceDelta d = _swap(true, 1_000_000 ether, 1 ether);
        assertEq(uint256(int256(d.amount1())), 1_000_000 ether);
        uint256 paid = uint256(-int256(d.amount0()));
        uint256 fee = _claims();
        assertApproxEqAbs(fee, (paid - fee) * 300 / 10_000, 1, "3% on top of pool input");
    }

    function test_feeOnExactOutputSell() public {
        BalanceDelta d = _swap(false, 0.1 ether, 0);
        assertEq(uint256(int256(d.amount0())), 0.1 ether, "trader gets exactly what they asked");
        assertEq(_claims(), 0.003 ether);
    }

    // ───────────── доступ ─────────────

    function test_onlyInitializerAndOnlyOnePool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        MANAGER.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
    }

    function test_onlyKeeperRunsOutcomes() public {
        _fillEpoch();
        arbBlock = hook.targetBlock() + 5;
        _setArbBlock(arbBlock);
        vm.startPrank(trader);
        vm.expectRevert(RouletteHook.NotKeeper.selector);
        hook.reveal(chain[1]);
        vm.expectRevert(RouletteHook.NotKeeper.selector);
        hook.executeBurn(1);
        vm.expectRevert(RouletteHook.NotKeeper.selector);
        hook.executeDip(1);
        vm.expectRevert(RouletteHook.NotKeeper.selector);
        hook.rolloverDip();
        vm.expectRevert(RouletteHook.NotKeeper.selector);
        hook.poke();
        vm.stopPrank();
    }

    function test_onlyOwnerChangesKeeper() public {
        vm.prank(trader);
        vm.expectRevert(RouletteHook.NotOwner.selector);
        hook.setKeeper(trader);
        address newKeeper = makeAddr("newKeeper");
        vm.prank(dev);
        hook.setKeeper(newKeeper);
        assertEq(hook.keeper(), newKeeper);
    }

    // ───────────── розыгрыш = исполнение ─────────────

    /// Каждый раунд: пот исполняется в той же транзакции, что и раскрытие. Проверяем все 4 исхода.
    function test_revealExecutesOutcomeImmediately() public {
        bool[4] memory seen;
        for (uint256 e; e < 60 && !(seen[0] && seen[1] && seen[2] && seen[3]); e++) {
            _fillEpoch();
            uint256 pot = hook.epochPot();
            uint256 supply = token.totalSupply();
            uint256 dip = hook.dipJar();
            uint256 donated = hook.totalToHolders();
            uint128 locked = hook.lockedLiquidity();
            _reveal();
            assertFalse(hook.awaiting());
            assertEq(hook.epochPot(), 0);
            if (token.totalSupply() < supply) seen[0] = true; // Burn
            else if (hook.dipJar() == dip + pot) seen[1] = true; // Dip ждёт бота
            else if (hook.totalToHolders() == donated + pot) seen[2] = true; // LP rewards
            else if (hook.lockedLiquidity() > locked) seen[3] = true; // Full-range
            else revert("no outcome effect");
        }
        assertTrue(seen[0] && seen[1] && seen[2] && seen[3], "all four outcomes ran");
        assertEq(_claims(), _accounted(), "every wei of the hook's ETH is accounted for");
    }

    function test_missedWindowFallsBackToBurnJar() public {
        _fillEpoch();
        uint256 pot = hook.epochPot();
        _setArbBlock(hook.targetBlock() + 300);
        vm.prank(keeper);
        hook.poke();
        assertEq(hook.burnJar(), pot);
        assertEq(hook.lastSecret(), chain[0], "secret not consumed");

        uint256 supply = token.totalSupply();
        vm.prank(keeper);
        hook.executeBurn(pot);
        assertLt(token.totalSupply(), supply, "burn jar bought and burned");
        assertEq(hook.burnJar(), 0);
    }

    function test_dipWaitsForKeeperThenRollsOver() public {
        for (uint256 e; e < 60 && hook.dipJar() == 0; e++) {
            _fillEpoch();
            _reveal();
        }
        uint256 dip = hook.dipJar();
        assertGt(dip, 0, "a Dip round happened");

        // бот увидел просадку и купил часть банки
        uint256 supply = token.totalSupply();
        vm.prank(keeper);
        hook.executeDip(dip / 2);
        assertLt(token.totalSupply(), supply);

        // остальное за сутки так и не дождалось просадки — уходит в Burn
        vm.prank(keeper);
        vm.expectRevert(RouletteHook.NotReady.selector);
        hook.rolloverDip();
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 rest = hook.dipJar();
        uint256 burnBefore = hook.burnJar();
        vm.prank(keeper);
        hook.rolloverDip();
        assertEq(hook.dipJar(), 0);
        assertEq(hook.burnJar(), burnBefore + rest);
    }

    function test_devClaim() public {
        _buy(1 ether);
        hook.claimDev();
        assertEq(dev.balance, 0.01 ether);
        assertEq(hook.devAccrued(), 0);
        assertEq(_claims(), 0.02 ether);
    }
}
