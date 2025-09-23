// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

interface IVaultOwner {
    function transfer_vault_ownership(address newOwner) external;
}

/**
 * @title DeployMigratorRouter
 * @notice Deploys the V1→V2 migration router using address book defaults.
 */
contract DeployMigratorRouter is Script {
    using stdJson for string;

    string internal constant ADDRESS_BOOK_PATH = "addresses/base.json";
    string internal constant OLD_ROUTER_JSON_KEY = ".rescue_router";
    string internal constant VAULT_V2_JSON_KEY = ".vault_v2";

    string internal constant OLD_ROUTER_ENV = "MIGRATOR_ROUTER_OLD_ROUTER";
    string internal constant VAULT_V2_ENV = "MIGRATOR_ROUTER_VAULT_V2";

    address public migratorRouter;

    function run() external {
        (address oldRouter, address vaultV2) = _resolveConstructorInputs();

        console.log("Deploying MigratorRouter");
        console.log("old router", oldRouter);
        console.log("vault v2", vaultV2);

        require(oldRouter != address(0), "Deploy: old router missing");
        require(vaultV2 != address(0), "Deploy: vault v2 missing");

        vm.startBroadcast();
        migratorRouter = _deployMigratorRouter(oldRouter, vaultV2);
        IVaultOwner(oldRouter).transfer_vault_ownership(migratorRouter);
        vm.stopBroadcast();

        console.log("MigratorRouter deployed at", migratorRouter);
    }

    function _resolveConstructorInputs() internal view returns (address oldRouter, address vaultV2) {
        oldRouter = vm.envOr(OLD_ROUTER_ENV, address(0));
        vaultV2 = vm.envOr(VAULT_V2_ENV, address(0));

        if (oldRouter != address(0) && vaultV2 != address(0)) {
            return (oldRouter, vaultV2);
        }

        string memory json = vm.readFile(ADDRESS_BOOK_PATH);

        if (oldRouter == address(0)) {
            oldRouter = json.readAddress(OLD_ROUTER_JSON_KEY);
        }

        if (vaultV2 == address(0)) {
            vaultV2 = json.readAddress(VAULT_V2_JSON_KEY);
        }
    }

    function _deployMigratorRouter(address oldRouter, address vaultV2) internal returns (address) {
        bytes memory constructorArgs = abi.encode(oldRouter, vaultV2);
        bytes memory initCode = abi.encodePacked(vm.getCode("MigratorRouter.vy"), constructorArgs);

        address deployed;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }

        require(deployed != address(0), "Deploy: create failed");
        return deployed;
    }
}
