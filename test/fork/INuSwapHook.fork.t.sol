// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {HookMiner} from "../../script/HookMiner.sol";
import {INuSwapHook} from "../../src/INuSwapHook.sol";
import {Addresses} from "../../script/Addresses.sol";

interface IPositionManager {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// The hook against the REAL Robinhood Chain PoolManager, PositionManager, Permit2 and tokens.
/// Deploys and creates the pool exactly the way the mainnet scripts will. Nothing is broadcast.
/// forge test --match-path test/fork/INuSwapHook.fork.t.sol -vv
contract INuSwapHookForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(Addresses.POOL_MANAGER);
    IPositionManager constant POSM = IPositionManager(Addresses.POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(Addresses.PERMIT2);
    address constant CREATE2_DEPLOYER = Addresses.CREATE2_DEPLOYER;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address constant AI = Addresses.AI; // currency0 (lower address)
    address constant INU = Addresses.INU; // currency1
    /// The existing hookless AI/INU pool, used as the market price
    PoolId constant OLD_POOL = PoolId.wrap(Addresses.AI_INU_POOL);

    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 constant TICK_SPACING = 60;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;
    uint128 constant LIQUIDITY = 1e24; // ~150k AI + ~6.8M INU at today's price

    // PositionManager action codes (v4-periphery Actions.sol)
    uint8 constant DECREASE_LIQUIDITY = 0x01;
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant BURN_POSITION = 0x03;
    uint8 constant SETTLE_PAIR = 0x0d;
    uint8 constant TAKE_PAIR = 0x11;

    INuSwapHook hook;
    PoolKey key;
    PoolSwapTest router;
    uint256 lpTokenId;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        // Deploy the hook through the CREATE2 deployer with a mined salt, like DeployHook.s.sol
        bytes memory args = abi.encode(MANAGER);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(INuSwapHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(INuSwapHook).creationCode, args));
        require(ok && expected.code.length > 0, "hook deploy failed");
        hook = INuSwapHook(expected);

        router = new PoolSwapTest(MANAGER);

        // Fund wallets from tokens the PoolManager holds (fork only)
        _fund(lp, 1_000_000e18, 20_000_000e18);
        _fund(trader, 1_000_000e18, 5_000_000e18);

        key = PoolKey(Currency.wrap(AI), Currency.wrap(INU), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hook));
        lpTokenId = _createPoolAndMint(key, _marketPrice());

        vm.startPrank(trader);
        IERC20(AI).approve(address(router), type(uint256).max);
        IERC20(INU).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers
    function _fund(address to, uint256 ai, uint256 inu) internal {
        vm.startPrank(address(MANAGER));
        IERC20(AI).transfer(to, ai);
        IERC20(INU).transfer(to, inu);
        vm.stopPrank();
    }

    function _marketPrice() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = MANAGER.getSlot0(OLD_POOL);
    }

    /// Pool creation + full-range liquidity in ONE transaction, the way CreatePools will do it
    function _createPoolAndMint(PoolKey memory k, uint160 sqrtP) internal returns (uint256 tokenId) {
        vm.startPrank(lp);
        for (uint256 i; i < 2; i++) {
            address t = i == 0 ? AI : INU;
            IERC20(t).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(t, address(POSM), type(uint160).max, uint48(block.timestamp + 1 hours));
        }

        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            k, MIN_TICK, MAX_TICK, uint256(LIQUIDITY), type(uint128).max, type(uint128).max, lp, bytes("")
        );
        params[1] = abi.encode(k.currency0, k.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.initializePool, (k, sqrtP));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp));

        tokenId = POSM.nextTokenId();
        POSM.multicall(calls);
        vm.stopPrank();
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta d) {
        vm.prank(trader);
        d = router.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _dead(address t) internal view returns (uint256) {
        return IERC20(t).balanceOf(DEAD);
    }

    function _mult() internal view returns (uint8 m) {
        (m,,,) = hook.currentFees(key);
    }

    // ------------------------------------------------------------- tests

    function test_hookDeployedWithCorrectFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x10CC, "address flags");
        assertEq(address(hook.poolManager()), address(MANAGER));
    }

    function test_poolLaunchesAtMarketPriceAndCalm() public view {
        (uint160 sqrtP,,,) = MANAGER.getSlot0(key.toId());
        assertEq(sqrtP, _marketPrice(), "same price as the existing AI/INU pool");
        assertEq(MANAGER.getLiquidity(key.toId()), LIQUIDITY);
        assertEq(POSM.getPositionLiquidity(lpTokenId), LIQUIDITY, "LP owns the position NFT");
        (uint8 m,, uint24 lpFee, uint24 burnFee) = hook.currentFees(key);
        assertEq(m, 1);
        assertEq(lpFee, 3000);
        assertEq(burnFee, 2000);
    }

    /// Same trade as a plain 0.30% pool, minus exactly 0.1% burned from each side
    function test_calmExactIn_feesAndBurnsAreExact() public {
        PoolKey memory ref = PoolKey(Currency.wrap(AI), Currency.wrap(INU), 3000, TICK_SPACING, IHooks(address(0)));
        _createPoolAndMint(ref, _marketPrice());

        int256 amountIn = 100e18;
        uint256 burnIn = 100e18 * 1000 / 1e6;
        uint256 deadAI = _dead(AI);
        uint256 deadINU = _dead(INU);

        BalanceDelta d = _swap(key, true, -amountIn);
        BalanceDelta r = _swap(ref, true, -(amountIn - int256(burnIn)));
        uint256 poolOut = uint256(int256(r.amount1()));
        uint256 burnOut = poolOut * 1000 / 1e6;

        assertEq(d.amount0(), -amountIn, "trader paid exactly amountIn");
        assertEq(uint256(int256(d.amount1())), poolOut - burnOut, "trader got plain-pool output minus 0.1%");
        assertEq(_dead(AI) - deadAI, burnIn, "0.1% of AI burned");
        assertEq(_dead(INU) - deadINU, burnOut, "0.1% of INU burned");
        assertEq(hook.totalBurned(Currency.wrap(AI)), burnIn);
        assertEq(hook.burnedByPool(key.toId(), Currency.wrap(INU)), burnOut);
    }

    function test_exactOut_bothDirections() public {
        uint256 deadAI = _dead(AI);
        BalanceDelta d = _swap(key, false, 100e18); // buy exactly 100 AI with INU
        assertEq(d.amount0(), 100e18, "received exactly 100 AI");
        assertEq(_dead(AI) - deadAI, 100e18 * 1000 / 1e6, "0.1% of the AI side burned");

        uint256 deadINU = _dead(INU);
        d = _swap(key, true, 1000e18); // buy exactly 1000 INU with AI
        assertEq(d.amount1(), 1000e18, "received exactly 1000 INU");
        assertEq(_dead(INU) - deadINU, 1000e18 * 1000 / 1e6, "0.1% of the INU side burned");
    }

    function test_mediumMoveIs2x() public {
        _swap(key, true, -3_750e18); // ~2.5% of the pool's AI -> ~5% price move
        assertEq(_mult(), 2);
    }

    function test_dumpGoes3xThenDecaysToCalm() public {
        _swap(key, true, -10_000e18); // ~6.7% of the pool's AI -> ~13% price move
        (uint8 m, int24 gap0,,) = hook.currentFees(key);
        assertEq(m, 3, "wild after dump");
        assertGe(gap0, 950);

        vm.warp(block.timestamp + 512);
        (, int24 gap1,,) = hook.currentFees(key);
        assertApproxEqAbs(gap1, gap0 / 2, 1, "gap halves every 512s");

        vm.warp(block.timestamp + 512 * 4);
        assertEq(_mult(), 1, "calm again ~40 min later");
    }

    /// LP collects its 0.30% fees and then withdraws everything through the PositionManager
    function test_lpCollectsFeesAndWithdraws() public {
        for (uint256 i; i < 10; i++) {
            _swap(key, i % 2 == 0, i % 2 == 0 ? -int256(1_000e18) : -int256(45_000e18));
        }

        // Collect fees only: decrease by 0 liquidity, then take both tokens
        uint256 ai0 = IERC20(AI).balanceOf(lp);
        uint256 inu0 = IERC20(INU).balanceOf(lp);
        _lpAction(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), abi.encode(lpTokenId, uint256(0), uint128(0), uint128(0), bytes("")));
        uint256 feesAI = IERC20(AI).balanceOf(lp) - ai0;
        uint256 feesINU = IERC20(INU).balanceOf(lp) - inu0;

        // 5 swaps of 1,000 AI in -> 0.3% of the 999 AI that reached the pool, each
        assertApproxEqRel(feesAI, 5 * 999e18 * 3000 / 1e6, 1e15, "AI fees ~0.3% of AI volume");
        assertApproxEqRel(feesINU, 5 * 44_955e18 * 3000 / 1e6, 1e15, "INU fees ~0.3% of INU volume");

        // Full withdrawal
        _lpAction(abi.encodePacked(BURN_POSITION, TAKE_PAIR), abi.encode(lpTokenId, uint128(0), uint128(0), bytes("")));
        assertEq(MANAGER.getLiquidity(key.toId()), 0, "pool emptied");
        assertGt(IERC20(AI).balanceOf(lp), ai0 + feesAI);
        assertGt(IERC20(INU).balanceOf(lp), inu0 + feesINU);
    }

    function _lpAction(bytes memory actions, bytes memory firstParam) internal {
        bytes[] memory params = new bytes[](2);
        params[0] = firstParam;
        params[1] = abi.encode(key.currency0, key.currency1, lp);
        vm.prank(lp);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function test_counterMatchesDeadAddressOverManySwaps() public {
        uint256 deadAI = _dead(AI);
        uint256 deadINU = _dead(INU);
        for (uint256 i; i < 20; i++) {
            vm.warp(block.timestamp + 37);
            bool zf1 = i % 3 != 0;
            _swap(key, zf1, i % 2 == 0 ? -int256(50e18 + i * 1e18) : int256(20e18 + i * 1e18));
        }
        assertEq(hook.totalBurned(Currency.wrap(AI)), _dead(AI) - deadAI);
        assertEq(hook.totalBurned(Currency.wrap(INU)), _dead(INU) - deadINU);
    }

    function test_rejectsStaticFeePool() public {
        PoolKey memory bad = PoolKey(Currency.wrap(AI), Currency.wrap(INU), 3000, TICK_SPACING, IHooks(hook));
        uint160 price = _marketPrice();
        vm.expectRevert();
        MANAGER.initialize(bad, price);
    }

    function test_onlyPoolManagerCanCallHook() public {
        vm.expectRevert(INuSwapHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
    }
}
