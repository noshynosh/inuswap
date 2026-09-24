// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Addresses} from "../../script/Addresses.sol";
import {PriceRoute} from "../../script/PriceRoute.sol";

/// The launch-price routes against live Robinhood Chain pools.
/// forge test --match-path test/fork/PriceRoute.fork.t.sol -vv
contract PriceRouteForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(Addresses.POOL_MANAGER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
    }

    /// token1 per token0, 1e18-scaled
    function _price(uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192);
    }

    function _poolPrice(bytes32 id) internal view returns (uint256) {
        (uint160 sqrtP,,,) = MANAGER.getSlot0(PoolId.wrap(id));
        return _price(sqrtP);
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// One hop, same pair: the route must reproduce the AI/INU pool's own price
    function test_aiRouteEqualsExistingPool() public view {
        (address t0, address t1) = _sorted(Addresses.INU, Addresses.AI);
        uint160 routed = PriceRoute.sqrtPriceX96(MANAGER, Addresses.priceRoute(Addresses.AI), t0, t1);
        (uint160 direct,,,) = MANAGER.getSlot0(PoolId.wrap(Addresses.AI_INU_POOL));
        assertApproxEqAbs(routed, direct, 2, "same pool, same price (rounding only)");
    }

    function test_boner() public {
        _checkTwoHop(Addresses.BONER, Addresses.BONER_AI_POOL);
    }

    function test_meme() public {
        _checkTwoHop(Addresses.MEME, Addresses.MEME_AI_POOL);
    }

    function test_moo() public {
        _checkTwoHop(Addresses.MOO, Addresses.MOO_AI_POOL);
    }

    /// Two hops: compare with an independent calculation from each pool's plain price
    function _checkTwoHop(address x, bytes32 xAiPool) internal {
        (address t0, address t1) = _sorted(Addresses.INU, x);
        uint256 routed = _price(PriceRoute.sqrtPriceX96(MANAGER, Addresses.priceRoute(x), t0, t1));

        // AI is the lowest address of the three, so it is currency0 in both source pools:
        uint256 inuPerAi = _poolPrice(Addresses.AI_INU_POOL); // INU per AI
        uint256 xPerAi = _poolPrice(xAiPool); // X per AI
        // token1 per token0 of the new pool
        uint256 expected = Addresses.INU < x
            ? FullMath.mulDiv(xPerAi, 1e18, inuPerAi) // X per INU
            : FullMath.mulDiv(inuPerAi, 1e18, xPerAi); // INU per X
        assertApproxEqRel(routed, expected, 1e12, "route matches independent math (1e-6)");
        emit log_named_decimal_uint("token1 per token0", routed, 18);
    }
}
