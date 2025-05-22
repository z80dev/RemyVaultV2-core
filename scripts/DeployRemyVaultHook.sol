// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/RemyVaultHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title DeployRemyVaultHook
 * @notice Script to deploy RemyVaultHook
 */
contract DeployRemyVaultHook is Script {
    // Deploy parameters - these would be set before deployment
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x0000000000000000000000000000000000000000); // Replace with actual address
    address public constant REMY_VAULT = 0x0000000000000000000000000000000000000000; // Replace with actual address
    address public constant FEE_RECIPIENT = 0x0000000000000000000000000000000000000000; // Replace with actual address
    uint256 public constant BUY_FEE = 250; // 2.5%

    function run() public returns (RemyVaultHook hook) {
        // Find a salt that will create a hook address with the correct prefix
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(0), // Start address
            uint160(address(POOL_MANAGER)), // Key to incorporate into address
            type(RemyVaultHook).creationCode, // Contract creation code
            abi.encode(
                POOL_MANAGER,
                REMY_VAULT,
                FEE_RECIPIENT,
                BUY_FEE
            ) // Constructor args
        );

        console.log("Found salt for hook deployment:", uint256(salt));
        console.log("Hook will be deployed at:", hookAddress);

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the hook with the calculated salt
        hook = new RemyVaultHook{salt: salt}(
            POOL_MANAGER,
            REMY_VAULT,
            FEE_RECIPIENT,
            BUY_FEE
        );

        // Verify that the deployed address matches what we calculated
        require(address(hook) == hookAddress, "Hook deployed at unexpected address");

        // Stop broadcasting transactions
        vm.stopBroadcast();

        console.log("RemyVaultHook deployed at:", address(hook));
        console.log("Vault Token:", address(hook.vaultToken()));
        console.log("NFT Collection:", address(hook.nftCollection()));
        console.log("Owner:", hook.owner());
        console.log("Fee Recipient:", hook.feeRecipient());
    }
}

/**
 * @title DeployRemyVaultHookGoerli
 * @notice Script to deploy RemyVaultHook on Goerli testnet with specific parameters
 */
contract DeployRemyVaultHookGoerli is DeployRemyVaultHook {
    // Override parameters for Goerli testnet
    // Update these addresses before deployment
    IPoolManager public constant POOL_MANAGER_GOERLI = IPoolManager(0x0000000000000000000000000000000000000000);
    address public constant REMY_VAULT_GOERLI = 0x0000000000000000000000000000000000000000;
    address public constant FEE_RECIPIENT_GOERLI = 0x0000000000000000000000000000000000000000;
    
    function run() public override returns (RemyVaultHook hook) {
        // Find a salt that will create a hook address with the correct prefix
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(0), // Start address
            uint160(address(POOL_MANAGER_GOERLI)), // Key to incorporate into address
            type(RemyVaultHook).creationCode, // Contract creation code
            abi.encode(
                POOL_MANAGER_GOERLI,
                REMY_VAULT_GOERLI,
                FEE_RECIPIENT_GOERLI,
                BUY_FEE
            ) // Constructor args
        );

        console.log("Found salt for hook deployment on Goerli:", uint256(salt));
        console.log("Hook will be deployed at:", hookAddress);

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the hook with the calculated salt
        hook = new RemyVaultHook{salt: salt}(
            POOL_MANAGER_GOERLI,
            REMY_VAULT_GOERLI,
            FEE_RECIPIENT_GOERLI,
            BUY_FEE
        );

        // Verify that the deployed address matches what we calculated
        require(address(hook) == hookAddress, "Hook deployed at unexpected address");

        // Stop broadcasting transactions
        vm.stopBroadcast();

        console.log("RemyVaultHook deployed on Goerli at:", address(hook));
        console.log("Vault Token:", address(hook.vaultToken()));
        console.log("NFT Collection:", address(hook.nftCollection()));
        console.log("Owner:", hook.owner());
        console.log("Fee Recipient:", hook.feeRecipient());
    }
}