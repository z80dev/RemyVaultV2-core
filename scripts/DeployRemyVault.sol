// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

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

    // Contract addresses will be set during deployment
    address public managedToken;
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
        
        // 1. Deploy ManagedToken (REMY token)
        managedToken = deployManagedToken("REMY Token", "REMY", deployer);
        console.log("ManagedToken (REMY) deployed at:", managedToken);
        
        // 2. Deploy RemyVault
        remyVault = deployRemyVault(NFT_COLLECTION, managedToken, INITIAL_OWNER);
        console.log("RemyVault deployed at:", remyVault);
        
        // 3. Transfer ManagedToken management to RemyVault
        transferManagedTokenManagement(managedToken, remyVault);
        console.log("Management of REMY token transferred to RemyVault");
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Summary ===");
        console.log("ManagedToken (REMY):", managedToken);
        console.log("RemyVault:", remyVault);
        console.log("NFT Collection:", NFT_COLLECTION);
        console.log("Owner:", INITIAL_OWNER);
    }
    
    function deployManagedToken(
        string memory name,
        string memory symbol,
        address manager
    ) internal returns (address) {
        bytes memory constructorArgs = abi.encode(name, symbol, manager);
        bytes memory initCode = abi.encodePacked(
            vm.getCode("ManagedToken.vy"),
            constructorArgs
        );
        
        address deployed = ICreateX(CREATEX_FACTORY).deployCreate(initCode);
        require(deployed != address(0), "Failed to deploy ManagedToken");
        return deployed;
    }
    
    function deployRemyVault(
        address nftCollection,
        address token,
        address owner
    ) internal returns (address) {
        bytes memory constructorArgs = abi.encode(nftCollection, token, owner);
        bytes memory initCode = abi.encodePacked(
            vm.getCode("RemyVault.vy"),
            constructorArgs
        );
        
        address deployed = ICreateX(CREATEX_FACTORY).deployCreate(initCode);
        require(deployed != address(0), "Failed to deploy RemyVault");
        return deployed;
    }
    
    function transferManagedTokenManagement(
        address token,
        address newManager
    ) internal {
        (bool success, ) = token.call(
            abi.encodeWithSignature("change_manager(address)", newManager)
        );
        require(success, "Failed to transfer management");
    }
}