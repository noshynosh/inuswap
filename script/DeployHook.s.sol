// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "./HookMiner.sol";
import {INuSwapHook} from "../src/INuSwapHook.sol";
import {Addresses} from "./Addresses.sol";

/// forge script script/DeployHook.s.sol --rpc-url robinhood --account deployer --broadcast
/// The key lives in Foundry's encrypted keystore (`cast wallet import deployer -i`).
contract DeployHook is Script {
    function run() external returns (INuSwapHook hook) {
        IPoolManager manager = IPoolManager(Addresses.POOL_MANAGER);
        require(Addresses.CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer missing on this chain");

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) =
            HookMiner.find(Addresses.CREATE2_DEPLOYER, flags, type(INuSwapHook).creationCode, abi.encode(manager));

        vm.startBroadcast();
        hook = new INuSwapHook{salt: salt}(manager);
        vm.stopBroadcast();

        require(address(hook) == expected, "hook address mismatch");
        console.log("iNuSwap hook deployed at", address(hook));
    }
}
