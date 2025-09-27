// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DeployProtocol is Script {
    using stdJson for string;

    string internal constant ADDRESS_BOOK_PATH = "addresses/base.json";
    string internal constant POOL_MANAGER_JSON_KEY = ".pool_manager";

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    // Impersonated deployer used throughout the existing scripts/tests.
    address internal constant DEPLOYER = 0x70f4b83795Af9236dA8211CDa3b031E503C00970;

    function run() external {
        address poolManagerAddress = _resolvePoolManager();
        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        console2.log("pool manager", poolManagerAddress);

        bytes memory hookArgs = abi.encode(poolManager, DEPLOYER);
        (address predictedHook, bytes32 hookSalt) =
            HookMiner.find(DEPLOYER, HOOK_FLAGS, type(RemyVaultHook).creationCode, hookArgs);
        console2.log("predicted RemyVaultHook", predictedHook);
        console2.logBytes32(hookSalt);

        vm.startPrank(DEPLOYER);
        RemyVaultHook hook = new RemyVaultHook{salt: hookSalt}(poolManager, DEPLOYER);
        require(address(hook) == predictedHook, "Deploy: hook address mismatch");
        console2.log("RemyVaultHook deployed", address(hook));

        RemyVaultFactory vaultFactory = new RemyVaultFactory();
        console2.log("RemyVaultFactory deployed", address(vaultFactory));

        DerivativeFactory derivativeFactory = new DerivativeFactory(vaultFactory, hook, DEPLOYER);
        console2.log("DerivativeFactory deployed", address(derivativeFactory));

        hook.transferOwnership(address(derivativeFactory));
        vm.stopPrank();
        console2.log("hook ownership moved to factory", hook.owner());

        console2.log("=== Deployment Summary ===");
        console2.log("RemyVaultHook", address(hook));
        console2.log("RemyVaultFactory", address(vaultFactory));
        console2.log("DerivativeFactory", address(derivativeFactory));
    }

    function _resolvePoolManager() internal view returns (address poolManager) {
        poolManager = vm.envOr("POOL_MANAGER", address(0));
        if (poolManager != address(0)) {
            return poolManager;
        }

        try vm.readFile(ADDRESS_BOOK_PATH) returns (string memory json) {
            try vm.parseJsonAddress(json, POOL_MANAGER_JSON_KEY) returns (address parsed) {
                poolManager = parsed;
            } catch {}
        } catch {}

        require(poolManager != address(0), "Deploy: pool manager missing");
    }
}
