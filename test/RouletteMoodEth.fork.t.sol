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
import {RouletteTokenEth as RouletteToken} from "../src/RouletteTokenEth.sol";

/// Настроение хамелеона на запущенном пуле (2 ETH FDV, как в launch.eth.json).
contract RouletteMoodEthForkTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    int24 constant START_TICK = 200_280;

    RouletteInitializerEth init;
    RouletteToken token;
    RouletteHookEth hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address keeper = makeAddr("keeper");
    address trader = makeAddr("trader");
    bytes32[] chain;
    uint256 nextSecret = 1;

    function setUp() public {
        vm.createSelectFork("ethereum");
        chain = new bytes32[](101);
        chain[100] = keccak256("mood test seed");
        for (uint256 i = 100; i > 0; i--) {
            chain[i - 1] = keccak256(abi.encode(chain[i]));
        }
        init = new RouletteInitializerEth(MANAGER);
        token = new RouletteToken("TEST", "TEST", 1_000_000_000 ether, address(init), address(MANAGER));
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

    function _buy(uint256 eth) internal returns (uint256 tokensOut) {
        tokensOut = uint256(int256(_swap(true, -int256(eth), eth).amount1()));
    }

    function _sell(uint256 tokens) internal {
        _swap(false, -int256(tokens), 0);
    }

    /// Раунд из пар «купить на eth — продать купленное»: цена почти не меняется, объём ≈ 2·eth на пару.
    function _flatRound(uint256 eth) internal {
        for (uint256 i; i < 17; i++) {
            _sell(_buy(eth));
        }
    }

    function _reveal() internal returns (uint256 roll) {
        vm.roll(hook.targetBlock() + 5);
        for (uint256 x = block.number - 260; x < block.number; x++) {
            vm.setBlockhash(x, keccak256(abi.encode("block", x)));
        }
        bytes32 secret = chain[nextSecret++];
        roll = uint256(keccak256(abi.encode(secret, blockhash(hook.targetBlock()), hook.epochId(), address(hook)))) % 100;
        vm.prank(keeper);
        hook.reveal(secret);
    }

    // ───────────── шансы ─────────────

    function test_oddsAre55_15_15_15ForEveryMood() public view {
        for (uint8 m; m < 4; m++) {
            RouletteHookEth.Mood mood = RouletteHookEth.Mood(m);
            uint256[4] memory n;
            for (uint256 r; r < 100; r++) {
                n[uint8(hook.outcomeFor(r, mood))]++;
            }
            uint8 fav = uint8(hook.favoredOutcome(mood));
            for (uint8 o; o < 4; o++) {
                assertEq(n[o], o == fav ? 55 : 15, "55% favored, 15% each other");
            }
        }
        assertEq(uint8(hook.favoredOutcome(RouletteHookEth.Mood.Calm)), uint8(RouletteHookEth.Outcome.HolderRewards));
        assertEq(uint8(hook.favoredOutcome(RouletteHookEth.Mood.Busy)), uint8(RouletteHookEth.Outcome.FullRange));
        assertEq(uint8(hook.favoredOutcome(RouletteHookEth.Mood.Hungry)), uint8(RouletteHookEth.Outcome.Dip));
        assertEq(uint8(hook.favoredOutcome(RouletteHookEth.Mood.Excited)), uint8(RouletteHookEth.Outcome.Burn));
    }

    // ───────────── настроения ─────────────

    function test_buyingRoundIsExcitedThenSellingRoundIsHungry() public {
        uint256 bag;
        for (uint256 i; i < 33; i++) {
            bag += _buy(0.02 ether);
        }
        assertTrue(hook.awaiting());
        assertEq(uint8(hook.epochMood()), uint8(RouletteHookEth.Mood.Excited), "price up >= 5%");
        _reveal();

        // Цена всего второго раунда ниже средней первого: сначала крупная продажа, потом мелкие.
        _sell(bag / 2);
        for (uint256 i; i < 32; i++) {
            _sell(bag / 70);
        }
        assertEq(uint8(hook.epochMood()), uint8(RouletteHookEth.Mood.Hungry), "average price down >= 5%");
    }

    function test_flatRoundsAreCalmUntilVolumeJumps() public {
        _flatRound(0.01 ether);
        assertEq(uint8(hook.epochMood()), uint8(RouletteHookEth.Mood.Calm), "first round: no usual volume yet");
        _reveal();
        _flatRound(0.01 ether);
        assertEq(uint8(hook.epochMood()), uint8(RouletteHookEth.Mood.Calm), "same volume");
        _reveal();
        _flatRound(0.02 ether);
        assertEq(uint8(hook.epochMood()), uint8(RouletteHookEth.Mood.Busy), "2x usual volume");
    }

    function test_revealFollowsRollAndMood() public {
        for (uint256 e; e < 6; e++) {
            _flatRound(e % 2 == 0 ? 0.01 ether : 0.03 ether);
            uint256 supply = token.totalSupply();
            uint256 dip = hook.dipJar();
            uint256 donated = hook.totalToHolders();
            uint128 locked = hook.lockedLiquidity();
            uint256 pot = hook.epochPot();
            RouletteHookEth.Mood mood = hook.epochMood();
            uint256 roll = _reveal();
            RouletteHookEth.Outcome expected = hook.outcomeFor(roll, mood);
            if (expected == RouletteHookEth.Outcome.Burn) assertLt(token.totalSupply(), supply, "burn");
            else if (expected == RouletteHookEth.Outcome.Dip) assertEq(hook.dipJar(), dip + pot, "dip");
            else if (expected == RouletteHookEth.Outcome.HolderRewards) assertEq(hook.totalToHolders(), donated + pot, "lp");
            else assertGt(hook.lockedLiquidity(), locked, "full range");
        }
    }

    function test_midRoundSwapGas() public {
        _buy(0.01 ether); // первая запись в счётчики — один раз за жизнь пула
        _buy(0.01 ether);
        uint256 g = gasleft();
        _buy(0.01 ether);
        uint256 used = g - gasleft();
        emit log_named_uint("gas of a counted mid-round buy (router + pool + hook)", used);
        assertLt(used, 200_000);
    }
}
