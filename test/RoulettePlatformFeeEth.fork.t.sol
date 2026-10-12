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

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Доказательства для проверки Programmable: 0,30% (30 bps) от валовой ETH-суммы на каждой сделке —
/// через сторонние роутеры (тестовый роутер v4 и Universal Router mainnet), на initial buy и на собственных
/// выкупах хука; зачисление на баланс PLATFORM_RECIPIENT и вывод только туда.
/// Каждый сценарий пишет в лог: evidence.<сценарий>.{grossNative,platformFee,expectedCeil30bps,platformAccruedDelta}.
contract RoulettePlatformFeeEthForkTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IUniversalRouter constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address constant RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    int24 constant START_TICK = 200_280;

    RouletteInitializerEth init;
    RouletteTokenEth token;
    RouletteHookEth hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    address keeper = makeAddr("leon-platform-fee-keeper");
    address trader = makeAddr("leon-platform-fee-trader");
    bytes32[] chain;
    uint256 nextSecret = 1;

    // формат параметров свапа развёрнутого Universal Router (v4-periphery без minHopPriceX36)
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function setUp() public {
        vm.createSelectFork("ethereum");
        chain = new bytes32[](201);
        chain[200] = keccak256("platform fee evidence seed");
        for (uint256 i = 200; i > 0; i--) chain[i - 1] = keccak256(abi.encode(chain[i]));
        init = new RouletteInitializerEth(MANAGER);
        token = new RouletteTokenEth("TEST", "TEST", 1_000_000_000 ether, address(init), address(MANAGER));
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x7777) << 144)
        );
        deployCodeTo(
            "RouletteHookEth.sol:RouletteHookEth",
            abi.encode(MANAGER, address(token), address(init), makeAddr("leon-platform-fee-dev"), keeper, chain[0], 0.0033 ether),
            hookAddr
        );
        hook = RouletteHookEth(hookAddr);
        key = hook.poolKey();
        vm.deal(address(this), 1 ether);
        uint256 pa0 = hook.platformAccrued();
        init.initialize{value: 0.01 ether}(address(hook), START_TICK); // initial buy в транзакции запуска
        _evidence("initial-buy", 0.01 ether, hook.platformAccrued() - pa0);

        swapRouter = new PoolSwapTest(MANAGER);
        vm.deal(trader, 100 ether);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _ceil30(uint256 gross) internal pure returns (uint256) {
        return (gross * 30 + 9_999) / 10_000;
    }

    function _evidence(string memory name, uint256 gross, uint256 accruedDelta) internal {
        emit log_named_uint(string.concat("evidence.", name, ".grossNative"), gross);
        emit log_named_uint(string.concat("evidence.", name, ".expectedCeil30bps"), _ceil30(gross));
        emit log_named_uint(string.concat("evidence.", name, ".platformAccruedDelta"), accruedDelta);
        assertEq(accruedDelta, _ceil30(gross), string.concat(name, ": exactly 30 bps of gross native, rounded up"));
    }

    function _swap(bool buy, int256 amountSpecified, uint256 value) internal returns (BalanceDelta d) {
        vm.prank(trader);
        d = swapRouter.swap{value: value}(
            key, SwapParams(buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, ""
        );
    }

    function test_initialBuyPaysPlatformFee() public view {
        assertEq(hook.platformAccrued(), _ceil30(0.01 ether), "0.3% of the 0.01 ETH initial buy");
    }

    function test_alternateRouterAllSwapTypes() public {
        uint256 pa = hook.platformAccrued();
        _swap(true, -int256(0.2 ether), 0.2 ether); // покупка, точный вход: gross = вход
        _evidence("buy-exact-in", 0.2 ether, hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        BalanceDelta d = _swap(true, 1_000_000 ether, 1 ether); // покупка, точный выход: gross = всё, что заплачено
        _evidence("buy-exact-out", uint256(-int256(d.amount0())), hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        uint256 claims = MANAGER.balanceOf(address(hook), 0);
        d = _swap(false, -int256(2_000_000 ether), 0); // продажа, точный вход: gross = выход пула до комиссий
        uint256 fee = MANAGER.balanceOf(address(hook), 0) - claims;
        _evidence("sell-exact-in", uint256(int256(d.amount0())) + fee, hook.platformAccrued() - pa);

        pa = hook.platformAccrued();
        claims = MANAGER.balanceOf(address(hook), 0);
        d = _swap(false, int256(0.01 ether), 0); // продажа, точный выход: gross = выход пула до комиссий
        fee = MANAGER.balanceOf(address(hook), 0) - claims;
        _evidence("sell-exact-out", uint256(int256(d.amount0())) + fee, hook.platformAccrued() - pa);
    }

    function test_universalRouterBuy() public {
        ExactInputSingleParams memory p = ExactInputSingleParams(key, true, uint128(0.05 ether), 1, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(address(0), uint256(0.05 ether)); // SETTLE_ALL ETH
        params[2] = abi.encode(address(token), uint256(1)); // TAKE_ALL токен
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", params);
        uint256 pa = hook.platformAccrued();
        vm.prank(trader);
        UR.execute{value: 0.05 ether}(hex"10", inputs, block.timestamp + 600);
        assertGt(token.balanceOf(trader), 0, "Universal Router buy delivered tokens");
        _evidence("universal-router-buy-exact-in", 0.05 ether, hook.platformAccrued() - pa);
    }

    function _round() internal {
        for (uint256 i; i < 33; i++) {
            if (i % 2 == 0) _swap(true, -int256(0.05 ether), 0.05 ether);
            else _swap(false, -int256(4_000_000 ether), 0);
        }
    }

    function _reveal() internal {
        vm.roll(hook.targetBlock() + 5);
        for (uint256 x = block.number - 260; x < block.number; x++) vm.setBlockhash(x, keccak256(abi.encode("block", x)));
        vm.prank(keeper);
        hook.reveal(chain[nextSecret++]);
    }

    function test_ownBuybacksAndRecipientCredit() public {
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        bool burn; bool full; bool dip;
        for (uint256 e; e < 80 && !(burn && full && dip); e++) {
            _round();
            uint256 pot = hook.epochPot();
            uint256 supply = token.totalSupply();
            uint256 dipJar = hook.dipJar();
            uint256 donated = hook.totalToHolders();
            uint256 pa = hook.platformAccrued();
            _reveal();
            uint256 delta = hook.platformAccrued() - pa;
            if (!burn && token.totalSupply() < supply) { burn = true; _evidence("own-burn-buyback", pot, delta); }
            else if (hook.dipJar() == dipJar + pot) { assertEq(delta, 0, "parked dip is not a trade"); }
            else if (hook.totalToHolders() == donated + pot) { assertEq(delta, 0, "holder rewards are not a trade"); }
            else if (!full && token.totalSupply() == supply) { full = true; _evidence("own-full-range-buy", pot / 2, delta); }
            if (!dip && hook.dipJar() > 0) {
                uint256 jar = hook.dipJar();
                pa = hook.platformAccrued();
                vm.prank(keeper);
                hook.executeDip(jar);
                dip = true;
                _evidence("own-dip-buyback", jar, hook.platformAccrued() - pa);
            }
        }
        assertTrue(burn && full && dip, "burn, full-range and dip buybacks all ran");

        uint256 owed = hook.platformAccrued();
        uint256 before = RECIPIENT.balance;
        vm.prank(makeAddr("leon-platform-fee-anyone"));
        hook.claimPlatform();
        emit log_named_uint("evidence.claim.platformAccruedBefore", owed);
        emit log_named_uint("evidence.claim.recipientBalanceDelta", RECIPIENT.balance - before);
        emit log_named_address("evidence.claim.recipient", RECIPIENT);
        assertEq(RECIPIENT.balance - before, owed, "the whole platform balance is credited to the recipient");
        assertEq(hook.platformAccrued(), 0);
    }
}
