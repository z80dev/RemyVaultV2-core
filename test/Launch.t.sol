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
import {AddressBook, CoreAddresses} from "./helpers/AddressBook.sol";

contract LaunchTest is BaseTest, AddressBook {

    CoreAddresses internal core;
    IRescueRouter public rescueRouter;
    address internal routerOwner;
    
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

    function _ensureVaultOwnedByRescueRouter() internal {
        address currentOwner = vaultV1.owner();
        if (currentOwner == address(rescueRouter)) {
            return;
        }

        address rescueRouterOwner = rescueRouter.owner();

        if (currentOwner == address(rescueRouterV2)) {
            vm.prank(rescueRouterOwner);
            rescueRouterV2.transfer_vault_ownership(address(rescueRouter));
        } else if (currentOwner == rescueRouterOwner) {
            vm.prank(rescueRouterOwner);
            vaultV1.transfer_owner(address(rescueRouter));
        } else {
            vm.prank(currentOwner);
            vaultV1.transfer_owner(address(rescueRouter));
        }

        assertEq(vaultV1.owner(), address(rescueRouter), "Failed to restore RescueRouter ownership");
    }

    function _ensureVaultOwnedByRescueRouterV2() internal {
        address currentOwner = vaultV1.owner();
        if (currentOwner == address(rescueRouterV2)) {
            return;
        }

        address rescueRouterOwner = rescueRouter.owner();

        if (currentOwner == address(rescueRouter)) {
            vm.prank(rescueRouterOwner);
            rescueRouter.transfer_vault_ownership(address(rescueRouterV2));
        } else if (currentOwner == rescueRouterOwner) {
            vm.prank(rescueRouterOwner);
            vaultV1.transfer_owner(address(rescueRouterV2));
        } else {
            vm.prank(currentOwner);
            vaultV1.transfer_owner(address(rescueRouterV2));
        }

        assertEq(vaultV1.owner(), address(rescueRouterV2), "Failed to route ownership to RescueRouterV2");
    }

    function setUp() public {
        core = loadCoreAddresses();
        rescueRouter = IRescueRouter(core.rescueRouter);
        routerOwner = rescueRouter.owner();

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
        vm.prank(routerOwner);
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
        vm.startPrank(routerOwner);

        // Transfer vault ownership from rescue router to the owner
        rescueRouter.transfer_vault_ownership(routerOwner);

        // Verify ownership was transferred
        address currentVaultOwner = vaultV1.owner();
        require(currentVaultOwner == routerOwner, "Vault ownership transfer failed");
        
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
        _ensureVaultOwnedByRescueRouterV2();

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

    function testVaultOwnershipRecoveryFromRescueRouter() public {
        address rescueRouterOwner = rescueRouter.owner();

        _ensureVaultOwnedByRescueRouter();

        // Step 1: Verify initial state - rescue router owns the vault
        assertEq(vaultV1.owner(), address(rescueRouter), "RescueRouter should own vault initially");

        // Step 2: Router owner reclaims vault ownership
        vm.prank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Step 3: Verify ownership transferred
        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner should now control vault");
    }

    function testVaultOwnershipRecoveryFromRescueRouterV2() public {
        address rescueRouterOwner = rescueRouter.owner();

        _ensureVaultOwnedByRescueRouter();

        // First transfer vault to RescueRouterV2
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.transfer_owner(address(rescueRouterV2));
        vm.stopPrank();
        
        assertEq(vaultV1.owner(), address(rescueRouterV2), "RescueRouterV2 should own vault");
        
        // Now recover from RescueRouterV2
        vm.prank(rescueRouterOwner);
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        
        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner should control vault again");
    }

    function testOwnershipChainTransfer() public {
        address rescueRouterOwner = rescueRouter.owner();
        address newOwner = address(0x123);

        _ensureVaultOwnedByRescueRouter();

        // Transfer: RescueRouter -> Owner -> RescueRouterV2 -> NewOwner
        vm.startPrank(rescueRouterOwner);

        // Get vault from RescueRouter
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        assertEq(vaultV1.owner(), rescueRouterOwner, "Step 1 failed");
        
        // Give to RescueRouterV2
        vaultV1.transfer_owner(address(rescueRouterV2));
        assertEq(vaultV1.owner(), address(rescueRouterV2), "Step 2 failed");
        
        // Transfer to new owner
        rescueRouterV2.transfer_vault_ownership(newOwner);
        vm.stopPrank();
        
        assertEq(vaultV1.owner(), newOwner, "Final owner incorrect");
    }

    function testFeeExemptionPersistsAcrossOwnershipChanges() public {
        address rescueRouterOwner = rescueRouter.owner();
        address testAddress = address(0x456);

        _ensureVaultOwnedByRescueRouter();

        // Get vault ownership and set fee exemption
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.set_fee_exempt(testAddress, true);

        // Transfer to RescueRouterV2 and back
        vaultV1.transfer_owner(address(rescueRouterV2));
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        vm.stopPrank();
        
        // Verify fee exemption still exists
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should persist");
    }

    function testCannotTransferVaultOwnershipAsNonOwner() public {
        address initialOwner = vaultV1.owner();

        // Try to transfer vault ownership as non-owner
        vm.prank(address(0x999));
        vm.expectRevert();
        rescueRouter.transfer_vault_ownership(address(0x999));

        // Verify vault still owned by rescue router
        assertEq(vaultV1.owner(), initialOwner, "Ownership should not change");
    }

    function testRouterOwnershipTransfer() public {
        address rescueRouterOwner = rescueRouter.owner();
        address newRouterOwner = address(0x789);
        
        // Transfer router ownership
        vm.prank(rescueRouterOwner);
        rescueRouterV2.transfer_owner(newRouterOwner);
        
        assertEq(rescueRouterV2.owner(), newRouterOwner, "Router ownership not transferred");
        
        // New owner should be able to control vault
        vm.prank(newRouterOwner);
        rescueRouterV2.transfer_vault_ownership(newRouterOwner);
    }

}
