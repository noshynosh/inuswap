// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Addresses} from "./Addresses.sol";

/// Read-only: prints price, tick and liquidity for a comma-separated list of v4 pool ids.
/// POOLS=0xabc...,0xdef... forge script script/PoolInfo.s.sol --rpc-url robinhood
contract PoolInfo is Script {
    using StateLibrary for IPoolManager;

    function run() external view {
        bytes32[] memory ids = vm.envBytes32("POOLS", ",");
        IPoolManager manager = IPoolManager(Addresses.POOL_MANAGER);
        for (uint256 i; i < ids.length; i++) {
            (uint160 sqrtP, int24 tick,,) = manager.getSlot0(PoolId.wrap(ids[i]));
            uint128 liq = manager.getLiquidity(PoolId.wrap(ids[i]));
            console.logBytes32(ids[i]);
            console.log("  price token1/token0 (1e18):", FullMath.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192));
            console.log("  tick:", tick);
            console.log("  liquidity:", liq);
        }
    }
}
