// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RouletteHookEth} from "../src/RouletteHookEth.sol";
import {RouletteInitializerEth} from "../src/RouletteInitializerEth.sol";
import {RouletteTokenEth} from "../src/RouletteTokenEth.sol";

/// Награды холдерам: токен начисляет ETH пропорционально балансу, пул и служебные адреса не участвуют.
contract RouletteRewardsEthForkTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    int24 constant START_TICK = 200_280;

    RouletteInitializerEth init;
    RouletteTokenEth token;
    RouletteHookEth hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address keeper = makeAddr("keeper");
    address alice = makeAddr("leon-rewards-holder-a-7f3");
    address bob = makeAddr("leon-rewards-holder-b-7f3");
    address carol = makeAddr("leon-rewards-holder-c-7f3");
    bytes32[] chain;
    uint256 nextSecret = 1;

    function setUp() public {
        vm.createSelectFork("ethereum");
        chain = new bytes32[](201);
        chain[200] = keccak256("rewards test seed");
        for (uint256 i = 200; i > 0; i--) {
            chain[i - 1] = keccak256(abi.encode(chain[i]));
        }
        init = new RouletteInitializerEth(MANAGER);
        token = new RouletteTokenEth("TEST", "TEST", 1_000_000_000 ether, address(init), address(MANAGER));
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo(
            "RouletteHookEth.sol:RouletteHookEth",
            abi.encode(MANAGER, address(token), address(init), makeAddr("dev"), keeper, chain[0], 0.0033 ether),
            hookAddr
        );
        hook = RouletteHookEth(hookAddr);
        key = hook.poolKey();
        init.initialize(address(hook), START_TICK);

        swapRouter = new PoolSwapTest(MANAGER);
        for (uint256 i; i < 3; i++) {
            address who = [alice, bob, carol][i];
            vm.deal(who, 100 ether);
            vm.prank(who);
            token.approve(address(swapRouter), type(uint256).max);
        }
    }

    function _buy(address who, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        BalanceDelta d = swapRouter.swap{value: eth}(
            key, SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1), settings, ""
        );
        return uint256(int256(d.amount1()));
    }

    function _sell(address who, uint256 tokens) internal {
        vm.prank(who);
        swapRouter.swap(key, SwapParams(false, -int256(tokens), TickMath.MAX_SQRT_PRICE - 1), settings, "");
    }

    function _reveal() internal {
        vm.roll(hook.targetBlock() + 5);
        for (uint256 x = block.number - 260; x < block.number; x++) {
            vm.setBlockhash(x, keccak256(abi.encode("block", x)));
        }
        vm.prank(keeper);
        hook.reveal(chain[nextSecret++]);
    }

    // ───────────── токен ─────────────

    function test_rewardsSplitByBalanceAndSkipPoolAndLaunchAccounts() public {
        _buy(alice, 0.1 ether);
        _buy(bob, 0.2 ether);
        uint256 a = token.balanceOf(alice);
        uint256 b = token.balanceOf(bob);
        assertEq(token.eligibleSupply(), a + b, "only holders count");

        (bool ok,) = address(token).call{value: 1 ether}("");
        assertTrue(ok);
        assertApproxEqAbs(token.claimable(alice), 1 ether * a / (a + b), 2);
        assertApproxEqAbs(token.claimable(bob), 1 ether * b / (a + b), 2);
        assertEq(token.claimable(address(MANAGER)), 0, "pool gets nothing");
        assertEq(token.claimable(address(init)), 0, "initializer gets nothing");
        assertEq(token.claimable(token.DEAD()), 0);
    }

    function test_lateBuyerGetsNothingFromEarlierRewards() public {
        _buy(alice, 0.1 ether);
        token.distribute{value: 1 ether}();
        _buy(bob, 0.1 ether);
        assertEq(token.claimable(bob), 0, "bought after the reward");
        assertApproxEqAbs(token.claimable(alice), 1 ether, 2);
    }

    function test_transferKeepsEarnedRewardsWithSender() public {
        _buy(alice, 0.1 ether);
        token.distribute{value: 1 ether}();
        uint256 bal = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(carol, bal);
        assertApproxEqAbs(token.claimable(alice), 1 ether, 2, "alice keeps what she earned");
        assertEq(token.claimable(carol), 0);
        token.distribute{value: 1 ether}();
        assertApproxEqAbs(token.claimable(carol), 1 ether, 2, "next reward goes to the new holder");
        assertApproxEqAbs(token.claimable(alice), 1 ether, 2);
    }

    function test_sellingStopsFutureRewards() public {
        uint256 got = _buy(alice, 0.1 ether);
        _buy(bob, 0.1 ether);
        _sell(alice, got);
        assertEq(token.balanceOf(alice), 0);
        token.distribute{value: 1 ether}();
        assertLe(token.claimable(alice), 1, "no balance, no new rewards");
        assertApproxEqAbs(token.claimable(bob), 1 ether, 2);
    }

    function test_claimPaysOnce() public {
        _buy(alice, 0.1 ether);
        token.distribute{value: 1 ether}();
        uint256 owed = token.claimable(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        token.claim();
        assertEq(alice.balance - before, owed);
        assertEq(token.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(RouletteTokenEth.NothingToClaim.selector);
        token.claim();
    }

    function test_rewardWaitsUntilThereAreHolders() public {
        token.distribute{value: 1 ether}();
        assertEq(token.pendingRewards(), 1 ether, "nobody eligible yet");
        _buy(alice, 0.1 ether);
        token.distribute{value: 0.5 ether}();
        assertEq(token.pendingRewards(), 0);
        assertApproxEqAbs(token.claimable(alice), 1.5 ether, 2, "pending reward is not lost");
    }

    // ───────────── исход Holder rewards в раунде ─────────────

    function test_holderRewardsOutcomePaysHolders() public {
        _buy(carol, 0.5 ether); // держит и не торгует
        bool seen;
        for (uint256 e; e < 60 && !seen; e++) {
            for (uint256 i; i < 17; i++) {
                _sell(alice, _buy(alice, 0.02 ether));
            }
            uint256 before = hook.totalToHolders();
            uint256 pot = hook.epochPot();
            _reveal();
            if (hook.totalToHolders() == before + pot && pot > 0) seen = true;
        }
        assertTrue(seen, "a Holder rewards round happened");
        assertGt(token.claimable(carol), 0, "a quiet holder earned ETH");
        uint256 sum = token.claimable(carol) + token.claimable(alice) + token.claimable(address(hook));
        assertApproxEqAbs(sum, token.totalRewards(), 10, "every wei is owed to someone");
        // на адресе форка могла лежать пыль, поэтому «не меньше»
        assertGe(address(token).balance, token.totalRewards() + token.pendingRewards());
    }
}
