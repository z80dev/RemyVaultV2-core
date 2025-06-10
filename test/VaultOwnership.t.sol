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

contract VaultOwnershipTest is BaseTest {

    IRescueRouter public constant rescueRouter = IRescueRouter(0x0fc6284bC4c2DAF3719fd64F3767f73B32edD79d);
    address owner = 0x70f4b83795Af9236dA8211CDa3b031E503C00970;
    
    // Typed interfaces from rescue router
    IRemyVaultV1 public vaultV1;
    IERC721 public nft;
    
    // RescueRouterV2 deployment
    IRescueRouter public rescueRouterV2;

    function setUp() public {
        // Get interfaces from rescue router
        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        nft = IERC721(rescueRouter.erc721_address());
        
        // Deploy RescueRouterV2
        address rescueRouterOwner = rescueRouter.owner();
        vm.prank(rescueRouterOwner);
        rescueRouterV2 = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));
    }

    function testInitialVaultOwnership() public {
        // Verify rescue router owns the vault initially
        assertEq(vaultV1.owner(), address(rescueRouter), "RescueRouter should own vault initially");
    }

    function testOwnerCanReclaimVaultFromRescueRouter() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // Owner reclaims vault ownership
        vm.prank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Verify ownership transferred
        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner should now control vault");
    }

    function testOwnerCanReclaimVaultFromRescueRouterV2() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // First transfer vault to owner, then to RescueRouterV2
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

    function testMultipleRouterTransfers() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // Transfer: RescueRouter -> Owner -> RescueRouterV2 -> Owner -> RescueRouter
        vm.startPrank(rescueRouterOwner);
        
        // Get from RescueRouter
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        assertEq(vaultV1.owner(), rescueRouterOwner);
        
        // Give to RescueRouterV2
        vaultV1.transfer_owner(address(rescueRouterV2));
        assertEq(vaultV1.owner(), address(rescueRouterV2));
        
        // Get back from RescueRouterV2
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        assertEq(vaultV1.owner(), rescueRouterOwner);
        
        // Give back to original RescueRouter
        vaultV1.transfer_owner(address(rescueRouter));
        assertEq(vaultV1.owner(), address(rescueRouter));
        
        vm.stopPrank();
    }

    function testUnauthorizedCannotTransferVaultOwnership() public {
        address attacker = address(0x999);
        
        // Try to transfer from RescueRouter as non-owner
        vm.prank(attacker);
        vm.expectRevert();
        rescueRouter.transfer_vault_ownership(attacker);
        
        // Verify vault still owned by rescue router
        assertEq(vaultV1.owner(), address(rescueRouter));
    }

    function testFeeExemptionAcrossOwnershipTransfers() public {
        address rescueRouterOwner = rescueRouter.owner();
        address testAddress = address(0x456);
        
        // Get vault ownership and set fee exemption
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.set_fee_exempt(testAddress, true);
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should be set");
        
        // Transfer through multiple routers
        vaultV1.transfer_owner(address(rescueRouterV2));
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        
        // Verify fee exemption persists
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should persist after transfers");
        
        // Remove fee exemption
        vaultV1.set_fee_exempt(testAddress, false);
        assertFalse(vaultV1.fee_exempt(testAddress), "Fee exemption should be removed");
        
        vm.stopPrank();
    }

    function testRouterOwnershipTransferAffectsVaultControl() public {
        address rescueRouterOwner = rescueRouter.owner();
        address newOwner = address(0x789);
        
        // First get vault to RescueRouterV2
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.transfer_owner(address(rescueRouterV2));
        
        // Transfer router ownership
        rescueRouterV2.transfer_owner(newOwner);
        vm.stopPrank();
        
        // Old owner can't control vault anymore
        vm.prank(rescueRouterOwner);
        vm.expectRevert();
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        
        // New owner can control vault
        vm.prank(newOwner);
        rescueRouterV2.transfer_vault_ownership(newOwner);
        assertEq(vaultV1.owner(), newOwner);
    }

    function testEmergencyRecoveryScenario() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // Simulate compromised scenario - vault given to unknown router
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Before giving to compromised router, ensure we can always recover
        // In real scenario, we would need the compromised router to have transfer_vault_ownership function
        // This test shows we maintain control as long as we control the vault directly
        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner has direct control");
        
        vm.stopPrank();
    }

    function testVaultOwnershipWithThirdPartyRouter() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // Deploy a third router that mimics RescueRouterV2
        vm.prank(rescueRouterOwner);
        IRescueRouter thirdRouter = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));
        
        // Transfer vault ownership through multiple routers
        vm.startPrank(rescueRouterOwner);
        
        // Get from original router
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Give to third router
        vaultV1.transfer_owner(address(thirdRouter));
        assertEq(vaultV1.owner(), address(thirdRouter));
        
        // Recover from third router
        thirdRouter.transfer_vault_ownership(rescueRouterOwner);
        assertEq(vaultV1.owner(), rescueRouterOwner);
        
        vm.stopPrank();
    }

    function testOwnershipRecoveryPath() public {
        address rescueRouterOwner = rescueRouter.owner();
        
        // This test documents the recovery path for vault ownership
        // Step 1: Router owner can always reclaim vault from any router they control
        vm.prank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        
        // Step 2: Once owner has direct control, they can transfer to any address
        vm.prank(rescueRouterOwner);
        vaultV1.transfer_owner(rescueRouterOwner); // Could be any trusted address
        
        // Key insight: As long as we control the router contracts, we can always recover vault ownership
        assertEq(vaultV1.owner(), rescueRouterOwner, "Recovery successful");
    }
}