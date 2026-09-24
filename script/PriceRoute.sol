// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// Chains live pool prices to price a pair that has no direct pool yet (e.g. INU -> AI -> BONER).
/// Works in sqrtPriceX96 space: r(A->B) = sqrt(B per A) * 2^96, and r(A->C) = r(A->B) * r(B->C) / 2^96.
library PriceRoute {
    using StateLibrary for IPoolManager;

    struct Hop {
        bytes32 pool; // an existing v4 pool containing both `from` and `to`
        address from;
        address to;
    }

    uint256 internal constant Q96 = 1 << 96;

    /// sqrt(token1 per token0) * 2^96 for the pair (token0, token1), priced along `hops`,
    /// which must lead from token0 to token1 or from token1 to token0.
    function sqrtPriceX96(IPoolManager manager, Hop[] memory hops, address token0, address token1)
        internal
        view
        returns (uint160)
    {
        require(token0 < token1, "unsorted pair");
        address start = hops[0].from;
        address end = hops[hops.length - 1].to;
        require((start == token0 && end == token1) || (start == token1 && end == token0), "route does not connect pair");

        uint256 r = Q96; // r(start -> start) = 1
        for (uint256 i; i < hops.length; i++) {
            if (i > 0) require(hops[i].from == hops[i - 1].to, "broken route");
            r = FullMath.mulDiv(r, _hop(manager, hops[i]), Q96);
        }
        // r = r(start -> end). The pool price is r(token0 -> token1).
        if (start == token1) r = FullMath.mulDiv(Q96, Q96, r);
        require(r > 0 && r < type(uint160).max, "price out of range");
        return uint160(r);
    }

    /// r(from -> to) from one pool's current price
    function _hop(IPoolManager manager, Hop memory h) private view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(PoolId.wrap(h.pool));
        require(sqrtP != 0, "route pool not initialized");
        // A pool stores sqrt(currency1 per currency0); currency0 is the lower address.
        return h.from < h.to ? sqrtP : FullMath.mulDiv(Q96, Q96, sqrtP);
    }
}
