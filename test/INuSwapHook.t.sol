// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {INuSwapHook} from "../src/INuSwapHook.sol";

contract INuSwapHookTest is Test, Deployers {
    using StateLibrary for *;

    INuSwapHook hook;
    PoolKey hooked; // dynamic-fee pool with our hook
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // Full-range liquidity, matching the planned seeding
    ModifyLiquidityParams FULL_RANGE =
        ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1_000e18, salt: 0});

    PoolSwapTest.TestSettings SETTINGS = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo("INuSwapHook.sol:INuSwapHook", abi.encode(manager), hookAddr);
        hook = INuSwapHook(hookAddr);

        (hooked,) = initPool(currency0, currency1, IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(hooked, FULL_RANGE, ZERO_BYTES);
    }

    // ------------------------------------------------------------ helpers
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SETTINGS,
            ZERO_BYTES
        );
    }

    function _dead(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(DEAD);
    }

    /// A plain, hookless pool with a fixed fee, at the same price & liquidity as `hooked`
    function _referencePool(uint24 fee) internal returns (PoolKey memory key) {
        (uint160 sqrtP,,,) = manager.getSlot0(hooked.toId());
        (key,) = initPool(currency0, currency1, IHooks(address(0)), fee, sqrtP);
        ModifyLiquidityParams memory p = FULL_RANGE;
        p.liquidityDelta = int256(uint256(manager.getLiquidity(hooked.toId())));
        modifyLiquidityRouter.modifyLiquidity(key, p, ZERO_BYTES);
    }

    function _mult() internal view returns (uint8 m) {
        (m,,,) = hook.currentFees(hooked);
    }

    // ------------------------------------------------------------- tests

    /// Calm market: trader pays 0.3% LP + 0.1% burned from input + 0.1% burned from output
    function test_calmExactIn_feesAndBurnsAreExact() public {
        PoolKey memory ref = _referencePool(3000); // plain 0.30% pool

        int256 amountIn = 1e18;
        uint256 burnIn = 1e18 * 1000 / 1e6; // 0.1%

        BalanceDelta d = _swap(hooked, true, -amountIn);
        // What a plain 0.3% pool gives for the input that actually reached the pool
        BalanceDelta r = _swap(ref, true, -(amountIn - int256(burnIn)));

        uint256 poolOut = uint256(int256(r.amount1()));
        uint256 burnOut = poolOut * 1000 / 1e6;

        assertEq(d.amount0(), -amountIn, "trader paid exactly amountIn");
        assertEq(uint256(int256(d.amount1())), poolOut - burnOut, "trader got output minus 0.1%");
        assertEq(_dead(currency0), burnIn, "0.1% of input burned");
        assertEq(_dead(currency1), burnOut, "0.1% of output burned");
        assertEq(hook.totalBurned(currency0), burnIn);
        assertEq(hook.burnedByPool(hooked.toId(), currency1), burnOut);
    }

    /// Exact-output swaps: trader receives exactly what they asked for, both sides still burn
    function test_calmExactOut_traderGetsExactAmount() public {
        int256 wantOut = 1e18;
        BalanceDelta d = _swap(hooked, false, wantOut); // buy token0 with token1

        assertEq(d.amount0(), wantOut, "received exactly wantOut");
        assertEq(_dead(currency0), 1e18 * 1000 / 1e6, "0.1% of specified (output) burned");
        uint256 paidIn = uint256(int256(-d.amount1()));
        uint256 burnedIn = _dead(currency1);
        assertGt(burnedIn, 0);
        // input-side burn is 0.1% of what went to the pool (paidIn = pool input + burn)
        assertApproxEqRel(burnedIn, (paidIn - burnedIn) / 1000, 1e14);
    }

    function test_bothDirectionsBurnBothTokens() public {
        _swap(hooked, true, -1e17);
        _swap(hooked, false, -1e17);
        assertGt(_dead(currency0), 0);
        assertGt(_dead(currency1), 0);
    }

    /// The dump itself is priced before it happens (1x); the NEXT trades see the gap
    function test_dumpRaisesFeesForFollowingSwaps() public {
        assertEq(_mult(), 1);
        _swap(hooked, true, -60e18); // ~12% price drop on 1000e18 liquidity
        (uint8 m, int24 gap,,) = hook.currentFees(hooked);
        assertEq(m, 3, "wild after big dump");
        assertGe(gap, 950);
    }

    function test_mediumMoveIs2x() public {
        _swap(hooked, true, -25e18); // ~5% move
        assertEq(_mult(), 2);
    }

    /// Fees in the wild state really are 3x: compare with a plain 0.9% pool at the same price
    function test_wildStateChargesTripleFees() public {
        _swap(hooked, true, -60e18);
        assertEq(_mult(), 3);
        PoolKey memory ref = _referencePool(9000); // plain 0.90% pool

        int256 amountIn = 1e18;
        uint256 burnIn = 1e18 * 3000 / 1e6; // 0.3% of input at 3x

        BalanceDelta d = _swap(hooked, false, -amountIn);
        BalanceDelta r = _swap(ref, false, -(amountIn - int256(burnIn)));
        uint256 poolOut = uint256(int256(r.amount0()));
        assertEq(uint256(int256(d.amount0())), poolOut - poolOut * 3000 / 1e6);
    }

    /// Gap halves every 512s, so fees step 3x -> 2x -> 1x at predictable times
    function test_feesDecayBackToNormal() public {
        _swap(hooked, true, -60e18);
        (uint8 m, int24 gap0,,) = hook.currentFees(hooked);
        assertEq(m, 3);

        vm.warp(block.timestamp + 512);
        (, int24 gap1,,) = hook.currentFees(hooked);
        assertApproxEqAbs(gap1, gap0 / 2, 1, "one half-life halves the gap");

        vm.warp(block.timestamp + 512 * 3); // 4 half-lives: gap / 16
        assertEq(_mult(), 1, "back to calm");
    }

    /// Same decay whether nobody trades or people trade every few seconds
    function test_decaySameWithOrWithoutSwaps() public {
        PoolKey memory quiet = hooked;
        (PoolKey memory busy,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(busy, FULL_RANGE, ZERO_BYTES);

        _swap(quiet, true, -60e18);
        _swap(busy, true, -60e18);

        for (uint256 i; i < 150; i++) {
            vm.warp(block.timestamp + 7);
            _swap(busy, false, -1e9); // dust trades
        }
        (, int24 gQuiet,,) = hook.currentFees(quiet);
        (, int24 gBusy,,) = hook.currentFees(busy);
        assertApproxEqAbs(gQuiet, gBusy, 2, "decay is swap-frequency independent");
    }

    /// Pushing the price around never lowers anyone's fee - it raises it
    function test_manipulationOnlyRaisesFees() public {
        _swap(hooked, true, -60e18);
        assertEq(_mult(), 3);
        // move price back toward reference -> fee falls, which is correct (price back to "normal")
        _swap(hooked, false, -60e18);
        assertLe(_mult(), 2);
    }

    function test_rejectsStaticFeePools() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_onlyPoolManagerCanCallHooks() public {
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(INuSwapHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), hooked, p, ZERO_BYTES);
    }

    /// LPs can still withdraw everything plus fees
    function test_lpCanWithdrawWithFees() public {
        for (uint256 i; i < 10; i++) {
            _swap(hooked, i % 2 == 0, -1e18);
        }
        uint256 b0 = currency0.balanceOfSelf();
        uint256 b1 = currency1.balanceOfSelf();
        ModifyLiquidityParams memory p = FULL_RANGE;
        p.liquidityDelta = -p.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(hooked, p, ZERO_BYTES);
        assertGt(currency0.balanceOfSelf(), b0);
        assertGt(currency1.balanceOfSelf(), b1);
        assertEq(manager.getLiquidity(hooked.toId()), 0);
    }

    /// Fuzz: any swap size/direction/type works, burns never exceed 0.3% per side, pool stays solvent
    function testFuzz_randomSwaps(uint256 seed) public {
        for (uint256 i; i < 8; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool zf1 = seed & 1 == 0;
            bool exactIn = seed & 2 == 0;
            uint256 amt = bound(seed >> 8, 1e6, 20e18);
            vm.warp(block.timestamp + (seed >> 200) % 20 minutes);

            uint256 dead0 = _dead(currency0);
            uint256 dead1 = _dead(currency1);
            BalanceDelta d = _swap(hooked, zf1, exactIn ? -int256(amt) : int256(amt));

            uint256 in_ = uint256(int256(zf1 ? -d.amount0() : -d.amount1()));
            uint256 out = uint256(int256(zf1 ? d.amount1() : d.amount0()));
            uint256 burnIn = zf1 ? _dead(currency0) - dead0 : _dead(currency1) - dead1;
            uint256 burnOut = zf1 ? _dead(currency1) - dead1 : _dead(currency0) - dead0;

            assertLe(burnIn, in_ * 3000 / 1e6 + 1, "input burn <= 0.3%");
            assertLe(burnOut, (out + burnOut) * 3000 / 1e6 + 1, "output burn <= 0.3%");
            if (exactIn) assertEq(in_, amt);
            else assertEq(out, amt);
        }
    }
}
