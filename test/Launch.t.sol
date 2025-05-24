// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {BaseTest} from "./BaseTest.t.sol";
import {IRemyVault} from "../src/interfaces/IRemyVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {IManagedToken} from "../src/interfaces/IManagedToken.sol";
import {IERC721Enumerable} from "../src/interfaces/IERC721Enumerable.sol";
import {IRemyVaultV1} from "../src/interfaces/IRemyVaultV1.sol";
import {IMigrator} from "../src/interfaces/IMigrator.sol";
import {IRescueRouter} from "../src/interfaces/IRescueRouter.sol";

contract LaunchTest is BaseTest {

    IRescueRouter public constant rescueRouter = IRescueRouter(0x0fc6284bC4c2DAF3719fd64F3767f73B32edD79d);
    address owner = 0x70f4b83795Af9236dA8211CDa3b031E503C00970;
    
    // Typed interfaces from rescue router
    IRemyVaultV1 public vaultV1;
    IERC20 public weth;
    address public router;
    address public v3router;
    IERC721 public nft;
    IERC20 public remyV1Token;
    IERC4626 public vaultContract;
    
    // RemyVaultV2 deployment
    IRemyVault public remyVaultV2;
    IERC20 public remyV2Token;
    
    // RescueRouterV2 deployment
    IRescueRouter public rescueRouterV2;
    
    // Migrator deployment
    IMigrator public migrator;

    uint256[] public tokenIds;

    function setUp() public {
        // Get interfaces from rescue router
        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        weth = IERC20(rescueRouter.weth());
        router = rescueRouter.router_address();
        v3router = rescueRouter.v3router_address();
        remyV1Token = IERC20(rescueRouter.erc20_address());
        nft = IERC721(rescueRouter.erc721_address());
        vaultContract = IERC4626(rescueRouter.erc4626_address());
        
        // Deploy RemyVaultV2
        // Deploy the ManagedToken for RemyVaultV2
        remyV2Token = IERC20(deployCode("ManagedToken", abi.encode("REMY", "REMY", address(this))));
        
        // Deploy RemyVaultV2 using the existing NFT address from rescue router
        remyVaultV2 = IRemyVault(deployCode("RemyVault", abi.encode(address(remyV2Token), address(nft))));
        
        // Transfer ownership of the token to RemyVaultV2
        IManagedToken(address(remyV2Token)).transfer_ownership(address(remyVaultV2));
        
        // Deploy RescueRouterV2
        address rescueRouterOwner = rescueRouter.owner();
        vm.prank(rescueRouterOwner);
        rescueRouterV2 = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));
        
        // Deploy Migrator with RescueRouterV2 and NFT address
        migrator = IMigrator(deployCode("Migrator", abi.encode(address(remyV1Token), address(remyV2Token), address(vaultV1), address(remyVaultV2), address(rescueRouterV2), address(nft))));
        
        // Preload migrator with 1000 REMY v2 tokens for handling leftover swaps
        // RemyVaultV2 owns the ManagedToken, so we impersonate it to add minting authority
        vm.startPrank(address(remyVaultV2));

        // Now mint 1000 REMY v2 tokens to the migrator
        IManagedToken(address(remyV2Token)).mint(address(migrator), 1000 * 10**18);
        vm.stopPrank();
        
        // Verify the migrator has the tokens
        uint256 migratorV2Balance = remyV2Token.balanceOf(address(migrator));
        require(migratorV2Balance == 1000 * 10**18, "Migrator should have 1000 REMY v2 tokens");
        
        // Exempt migrator from fees on v1 vault using the actual process
        // Step 1: Rescue router owner claims back ownership of the vault
        vm.startPrank(rescueRouterOwner);
        
        // Transfer vault ownership from rescue router to the owner
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Verify ownership was transferred
        address currentVaultOwner = vaultV1.owner();
        require(currentVaultOwner == rescueRouterOwner, "Vault ownership transfer failed");
        
        // Step 2: Set fee exemption for migrator AND RescueRouterV2
        vaultV1.set_fee_exempt(address(migrator), true);
        vaultV1.set_fee_exempt(address(rescueRouterV2), true);
        
        // Step 3: Transfer vault ownership to RescueRouterV2 (instead of back to rescue router)
        vaultV1.transfer_owner(address(rescueRouterV2));
        
        vm.stopPrank();
        
        // Verify ownership is with RescueRouterV2
        address finalVaultOwner = vaultV1.owner();
        require(finalVaultOwner == address(rescueRouterV2), "Vault ownership not transferred to RescueRouterV2");
        
        tokenIds = new uint256[](2);
        tokenIds[0] = 581;
        tokenIds[1] = 564;
    }

    function testFullMigrationWithUnstakingAndRescueRouterV2() public {
        // Get the actual NFT owner who has staked tokens
        address nftOwner = nft.ownerOf(tokenIds[0]);
        
        // Record initial balances
        uint256 initialShares = vaultContract.balanceOf(nftOwner);
        uint256 initialRemyV1 = remyV1Token.balanceOf(nftOwner);
        uint256 initialRemyV2 = remyV2Token.balanceOf(nftOwner);

        // Step 1: Unstake from ERC4626 to get REMY v1 tokens
        vm.startPrank(nftOwner);
        
        uint256 assetsToReceive = vaultContract.convertToAssets(initialShares);
        uint256 remyV1Received = vaultContract.redeem(initialShares, nftOwner, nftOwner);
        assertEq(assetsToReceive, remyV1Received, "Assets received should match expected");

        uint256 remyV1AfterUnstake = remyV1Token.balanceOf(nftOwner);
        assertEq(remyV1AfterUnstake, initialRemyV1 + remyV1Received, "REMY v1 balance should increase by assets received");
        
        // Step 2: Approve migrator to spend REMY v1
        remyV1Token.approve(address(migrator), remyV1AfterUnstake);
        
        // Step 3: Call migrate
        // Call migrate directly - will revert if it fails
        migrator.migrate();
        
        vm.stopPrank();
        
        // Step 4: Check final balances
        uint256 finalRemyV1 = remyV1Token.balanceOf(nftOwner);
        uint256 finalRemyV2 = remyV2Token.balanceOf(nftOwner);

        // Check migrator's final token balances
        (uint256 migratorV1Final, uint256 migratorV2Final) = migrator.get_token_balances();

        // Verify the invariant
        assertEq(migratorV1Final + migratorV2Final, 1000 * 10**18, "Migrator should maintain 1000 token invariant");
        
        // Assertions
        assertEq(finalRemyV1, 0, "User should have no REMY v1 left");
        assertGt(finalRemyV2, initialRemyV2, "User should have gained REMY v2");
        assertEq(remyV1AfterUnstake, finalRemyV2, "User should have exact amount migrated");
        
    }

}
