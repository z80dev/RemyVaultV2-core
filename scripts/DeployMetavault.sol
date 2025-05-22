// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

/**
 * @title MetavaultDeploymentScript
 * @dev Script to deploy the NFT Staking Metavault system
 */
contract MetavaultDeploymentScript is Script {
    // Contract addresses
    address public mvREMY;
    address public stakingVault;
    address public inventoryMetavault;
    address public remyVault;

    // Parameters for deployment
    string public constant MV_REMY_NAME = "Managed Vault REMY";
    string public constant MV_REMY_SYMBOL = "mvREMY";
    string public constant STAKING_VAULT_NAME = "Staking Metavault";
    string public constant STAKING_VAULT_SYMBOL = "stMV";
    string public constant EIP712_NAME = "Metavault Staking";
    string public constant EIP712_VERSION = "1";

    function run() external {
        // Start broadcasting transactions
        vm.startBroadcast();

        // 1. Get the RemyVault address
        remyVault = vm.envAddress("REMY_VAULT_ADDRESS");
        require(remyVault != address(0), "RemyVault address not set");

        // 2. Deploy ManagedToken (mvREMY)
        // We'll use the deployer as the initial manager and transfer later
        mvREMY = deployManagedToken(MV_REMY_NAME, MV_REMY_SYMBOL, msg.sender);
        console.log("ManagedToken (mvREMY) deployed at:", mvREMY);

        // 3. Deploy StakingVault with mvREMY as the underlying asset
        stakingVault = deployStakingVault(
            STAKING_VAULT_NAME,
            STAKING_VAULT_SYMBOL,
            mvREMY,
            0, // No decimals offset
            EIP712_NAME,
            EIP712_VERSION
        );
        console.log("StakingVault deployed at:", stakingVault);

        // 4. Deploy InventoryMetavault
        inventoryMetavault = deployInventoryMetavault(
            remyVault,
            mvREMY,
            stakingVault
        );
        console.log("InventoryMetavault deployed at:", inventoryMetavault);

        // 5. Post-deployment setup: Transfer mvREMY management to metavault
        transferManagedTokenManagement(mvREMY, inventoryMetavault);
        console.log("Management of mvREMY transferred to InventoryMetavault");

        vm.stopBroadcast();
    }

    function deployManagedToken(
        string memory name,
        string memory symbol,
        address manager
    ) internal returns (address) {
        // Deploy ManagedToken using Vyper deployment
        bytes memory args = abi.encode(name, symbol, manager);
        address deployed = deployVyperContract("ManagedToken", args);
        return deployed;
    }

    function deployStakingVault(
        string memory name,
        string memory symbol,
        address asset,
        uint8 decimalsOffset,
        string memory eip712Name,
        string memory eip712Version
    ) internal returns (address) {
        // Deploy StakingVault using Vyper deployment
        bytes memory args = abi.encode(
            name,
            symbol,
            asset,
            decimalsOffset,
            eip712Name,
            eip712Version
        );
        address deployed = deployVyperContract("StakingVault", args);
        return deployed;
    }

    function deployInventoryMetavault(
        address remyVaultAddress,
        address internalTokenAddress,
        address stakingVaultAddress
    ) internal returns (address) {
        // Deploy InventoryMetavault using Vyper deployment
        bytes memory args = abi.encode(
            remyVaultAddress,
            internalTokenAddress,
            stakingVaultAddress
        );
        address deployed = deployVyperContract("InventoryMetavault", args);
        return deployed;
    }

    function transferManagedTokenManagement(
        address token,
        address newManager
    ) internal {
        // Call the change_manager function on the ManagedToken
        (bool success, ) = token.call(
            abi.encodeWithSignature("change_manager(address)", newManager)
        );
        require(success, "Failed to transfer management");
    }

    function deployVyperContract(
        string memory contractName,
        bytes memory constructorArgs
    ) internal returns (address) {
        // This is a placeholder. In a real deployment script,
        // we would need to handle Vyper contract deployment.
        // For now, let's simply log that we're deploying.
        console.log("Deploying Vyper contract:", contractName);
        
        // In Foundry, we would typically use the deployCode function
        // But since we're working with Vyper, this is just a representation
        bytes memory bytecode = abi.encodePacked(
            vm.getCode(string(abi.encodePacked(contractName, ".vy")))
        );
        
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        
        require(deployed != address(0), "Failed to deploy contract");
        return deployed;
    }
}