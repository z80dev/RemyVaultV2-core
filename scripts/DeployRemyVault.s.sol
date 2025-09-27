// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {RemyVault} from "../src/RemyVault.sol";

interface ICreateX {
    function deployCreate(bytes memory initCode) external payable returns (address newContract);
}

/**
 * @title DeployRemyVault
 * @notice Script to deploy the core RemyVault system using CreateX
 */
contract DeployRemyVault is Script {
    // CreateX factory address (same on all chains)
    address constant CREATEX_FACTORY = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    
    // Deployment parameters - update these before deployment
    address public constant NFT_COLLECTION = 0x0000000000000000000000000000000000000000; // Replace with actual NFT collection
    address public constant INITIAL_OWNER = 0x0000000000000000000000000000000000000000; // Replace with actual owner

    // Contract address will be set during deployment
    address public remyVault;

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying RemyVault system with deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("NFT Collection:", NFT_COLLECTION);
        console.log("Initial Owner:", INITIAL_OWNER);
        
        require(NFT_COLLECTION != address(0), "NFT_COLLECTION address not set");
        require(INITIAL_OWNER != address(0), "INITIAL_OWNER address not set");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy RemyVault (self-managing ERC20)
        remyVault = deployRemyVault("REMY Token", "REMY", NFT_COLLECTION);
        console.log("RemyVault deployed at:", remyVault);

        // Transfer ownership to the desired owner if necessary
        if (INITIAL_OWNER != address(0)) {
            transferVaultOwnership(remyVault, INITIAL_OWNER);
            console.log("RemyVault ownership transferred to:", INITIAL_OWNER);
        }
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Summary ===");
        console.log("RemyVault:", remyVault);
        console.log("NFT Collection:", NFT_COLLECTION);
        console.log("Owner:", INITIAL_OWNER);
    }
    
    function deployRemyVault(
        string memory name,
        string memory symbol,
        address nftCollection
    ) internal returns (address) {
        bytes memory constructorArgs = abi.encode(name, symbol, nftCollection);
        bytes memory initCode = abi.encodePacked(type(RemyVault).creationCode, constructorArgs);

        address deployed = ICreateX(CREATEX_FACTORY).deployCreate(initCode);
        require(deployed != address(0), "Failed to deploy RemyVault");
        return deployed;
    }

    function transferVaultOwnership(address vault, address newOwner) internal {
        (bool success, ) = vault.call(abi.encodeWithSignature("transfer_ownership(address)", newOwner));
        require(success, "Failed to transfer vault ownership");
    }
}
