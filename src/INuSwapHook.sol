// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @title iNuSwap hook
/// @notice One hook shared by every iNuSwap pool. On each swap it:
///   1. Measures volatility: how far the live price is from a slow-moving reference price.
///   2. Picks a multiplier (1x calm, 2x choppy, 3x wild).
///   3. Charges LPs' fee = 0.30% x multiplier (paid to depositors by Uniswap as normal).
///   4. Charges buyback fee = 0.20% x multiplier, split 50/50: half taken from the token going in,
///      half from the token coming out, and both are sent straight to the dead address (burned).
/// Because the burn is taken from tokens the trade itself moves, there is no separate buyback
/// swap, no pot to manage, no keeper, and nothing for bots to front-run.
/// No owner, no admin keys, nothing upgradeable.
contract INuSwapHook is IHooks {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------- config
    /// Fees are in "pips": 1_000_000 = 100%. 3000 = 0.30%.
    uint24 public constant BASE_LP_FEE = 3000; // 0.30% to LPs at 1x
    uint24 public constant BASE_BURN_FEE_PER_SIDE = 1000; // 0.10% input + 0.10% output = 0.20% at 1x
    uint24 internal constant PIPS = 1_000_000;

    /// Gap between live tick and reference tick (1 tick ~= 0.01% price move)
    int24 public constant CHOPPY_GAP = 300; // ~3%  -> 2x
    int24 public constant WILD_GAP = 950; // ~10% -> 3x

    /// The gap between the reference and the live price halves every 512 seconds (~8.5 min).
    /// A power of two so whole seconds map exactly onto the fixed-point table below, which makes
    /// the decay identical whether there is one swap in that time or a thousand.
    uint256 public constant HALF_LIFE = 512;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;

    // ----------------------------------------------------------------- state
    struct Ref {
        int64 microTick; // reference (lagging) price, in millionths of a tick for precision
        uint40 lastUpdate; // when the reference was last moved
        uint8 mult; // multiplier of the latest swap (beforeSwap -> afterSwap); shares the slot, so no extra gas
    }

    mapping(PoolId => Ref) public refs;
    /// Total burned per pool per token, for the dashboard
    mapping(PoolId => mapping(Currency => uint256)) public burnedByPool;
    /// Total burned per token across all pools
    mapping(Currency => uint256) public totalBurned;

    // ---------------------------------------------------------------- events
    event Burned(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeeApplied(PoolId indexed poolId, uint8 multiplier, int24 gap, uint24 lpFee);

    // ---------------------------------------------------------------- errors
    error NotPoolManager();
    error MustUseDynamicFee();
    error HookNotImplemented();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------ initialize
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        refs[key.toId()] = Ref({microTick: int64(tick) * MICRO, lastUpdate: uint40(block.timestamp), mult: 1});
        return IHooks.afterInitialize.selector;
    }

    // ------------------------------------------------------------------ swap
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);

        // 1. Move the reference toward the live price, then measure the gap
        int64 ref = _catchUp(refs[id], tick);
        int24 gap = _gap(tick, ref);

        // 2. Multiplier, stored with the reference for afterSwap
        uint24 mult = gap < CHOPPY_GAP ? 1 : gap < WILD_GAP ? 2 : 3;
        refs[id] = Ref({microTick: ref, lastUpdate: uint40(block.timestamp), mult: uint8(mult)});

        // 3. LP fee for this swap
        uint24 lpFee = BASE_LP_FEE * mult;
        emit FeeApplied(id, uint8(mult), gap, lpFee);

        // 4. Burn half the buyback from the specified token (input for exact-in swaps)
        uint256 amountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 burn = amountSpecified * (BASE_BURN_FEE_PER_SIDE * mult) / PIPS;

        if (burn > 0) {
            bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
            _burn(id, specifiedIs0 ? key.currency0 : key.currency1, burn);
        }

        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(burn)), 0),
            lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        // Multiplier set by this swap's beforeSwap
        PoolId id = key.toId();
        uint256 mult = refs[id].mult;

        // Burn the other half from the unspecified token (output for exact-in swaps)
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency c, int128 amt) = specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (amt < 0) amt = -amt;

        uint256 burn = uint256(uint128(amt)) * (BASE_BURN_FEE_PER_SIDE * mult) / PIPS;
        if (burn > 0) _burn(id, c, burn);

        return (IHooks.afterSwap.selector, int128(int256(burn)));
    }

    // ----------------------------------------------------------------- views
    /// @notice What a swap would pay right now (for the dashboard / UI).
    function currentFees(PoolKey calldata key)
        external
        view
        returns (uint8 multiplier, int24 gap, uint24 lpFeePips, uint24 burnFeePips)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        gap = _gap(tick, _catchUp(refs[id], tick));
        multiplier = gap < CHOPPY_GAP ? 1 : gap < WILD_GAP ? 2 : 3;
        lpFeePips = BASE_LP_FEE * multiplier;
        burnFeePips = BASE_BURN_FEE_PER_SIDE * 2 * multiplier;
    }

    // -------------------------------------------------------------- internal
    int64 internal constant MICRO = 1e6;

    /// ref' = live + (ref - live) * 2^(-elapsed / HALF_LIFE)
    function _catchUp(Ref memory r, int24 tick) internal view returns (int64) {
        int64 live = int64(tick) * MICRO;
        uint256 elapsed = block.timestamp - r.lastUpdate;
        if (elapsed >= HALF_LIFE * 40) return live; // gap shrunk by 2^40: fully caught up

        uint256 f = 1e18 >> (elapsed / HALF_LIFE); // whole half-lives
        uint256 s = elapsed % HALF_LIFE; // leftover seconds, 0..511: multiply by 2^(-s/512)
        if (s & 256 != 0) f = f * 707106781186547524 / 1e18;
        if (s & 128 != 0) f = f * 840896415253714543 / 1e18;
        if (s & 64 != 0) f = f * 917004043204671231 / 1e18;
        if (s & 32 != 0) f = f * 957603280698573646 / 1e18;
        if (s & 16 != 0) f = f * 978572062087700134 / 1e18;
        if (s & 8 != 0) f = f * 989228013193975484 / 1e18;
        if (s & 4 != 0) f = f * 994599423483633175 / 1e18;
        if (s & 2 != 0) f = f * 997296056085470126 / 1e18;
        if (s & 1 != 0) f = f * 998647112890970173 / 1e18;

        return live + int64((int256(r.microTick) - int256(live)) * int256(f) / 1e18);
    }

    function _gap(int24 tick, int64 refMicro) internal pure returns (int24) {
        int256 d = (int256(tick) * MICRO - refMicro) / MICRO;
        return int24(d < 0 ? -d : d);
    }

    function _burn(PoolId id, Currency c, uint256 amount) internal {
        poolManager.take(c, BURN_ADDRESS, amount);
        burnedByPool[id][c] += amount;
        totalBurned[c] += amount;
        emit Burned(id, c, amount);
    }

    // ------------------------------------------------ unused hook functions
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
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

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
