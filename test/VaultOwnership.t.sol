// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {BaseTest} from "./BaseTest.t.sol";
import {IRemyVaultV1} from "../src/interfaces/IRemyVaultV1.sol";
import {IRescueRouter} from "../src/interfaces/IRescueRouter.sol";
import {AddressBook, CoreAddresses} from "./helpers/AddressBook.sol";

contract VaultOwnershipTest is BaseTest, AddressBook {

    CoreAddresses internal core;
    IRescueRouter public rescueRouter;
    address internal routerOwner;
    
    // Typed interfaces from rescue router
    IRemyVaultV1 public vaultV1;
    
    // RescueRouterV2 deployment
    IRescueRouter public rescueRouterV2;

    function setUp() public {
        core = loadCoreAddresses();

        rescueRouter = IRescueRouter(core.rescueRouter);
        routerOwner = rescueRouter.owner();

        // Get interfaces from rescue router
        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        
        // Deploy RescueRouterV2
        vm.prank(routerOwner);
        rescueRouterV2 = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));
    }

    function testInitialVaultOwnership() public {
        // Verify rescue router owns the vault initially
        assertEq(vaultV1.owner(), address(rescueRouter), "RescueRouter should own vault initially");
    }

    function testOwnerCanReclaimVaultFromRescueRouter() public {
        // Owner reclaims vault ownership
        vm.prank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);

        // Verify ownership transferred
        assertEq(vaultV1.owner(), routerOwner, "Owner should now control vault");
    }

    function testOwnerCanReclaimVaultFromRescueRouterV2() public {
        // First transfer vault to owner, then to RescueRouterV2
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
        vaultV1.transfer_owner(address(rescueRouterV2));
        vm.stopPrank();
        
        assertEq(vaultV1.owner(), address(rescueRouterV2), "RescueRouterV2 should own vault");
        
        // Now recover from RescueRouterV2
        vm.prank(routerOwner);
        rescueRouterV2.transfer_vault_ownership(routerOwner);
        
        assertEq(vaultV1.owner(), routerOwner, "Owner should control vault again");
    }

    function testMultipleRouterTransfers() public {
        // Transfer: RescueRouter -> Owner -> RescueRouterV2 -> Owner -> RescueRouter
        vm.startPrank(routerOwner);
        
        // Get from RescueRouter
        rescueRouter.transfer_vault_ownership(routerOwner);
        assertEq(vaultV1.owner(), routerOwner);
        
        // Give to RescueRouterV2
        vaultV1.transfer_owner(address(rescueRouterV2));
        assertEq(vaultV1.owner(), address(rescueRouterV2));
        
        // Get back from RescueRouterV2
        rescueRouterV2.transfer_vault_ownership(routerOwner);
        assertEq(vaultV1.owner(), routerOwner);
        
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
        address testAddress = address(0x456);
        
        // Get vault ownership and set fee exemption
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
        vaultV1.set_fee_exempt(testAddress, true);
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should be set");
        
        // Transfer through multiple routers
        vaultV1.transfer_owner(address(rescueRouterV2));
        rescueRouterV2.transfer_vault_ownership(routerOwner);
        
        // Verify fee exemption persists
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should persist after transfers");
        
        // Remove fee exemption
        vaultV1.set_fee_exempt(testAddress, false);
        assertFalse(vaultV1.fee_exempt(testAddress), "Fee exemption should be removed");
        
        vm.stopPrank();
    }

    function testRouterOwnershipTransferAffectsVaultControl() public {
        address newOwner = address(0x789);
        
        // First get vault to RescueRouterV2
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
        vaultV1.transfer_owner(address(rescueRouterV2));
        
        // Transfer router ownership
        rescueRouterV2.transfer_owner(newOwner);
        vm.stopPrank();
        
        // Old owner can't control vault anymore
        vm.prank(routerOwner);
        vm.expectRevert();
        rescueRouterV2.transfer_vault_ownership(routerOwner);
        
        // New owner can control vault
        vm.prank(newOwner);
        rescueRouterV2.transfer_vault_ownership(newOwner);
        assertEq(vaultV1.owner(), newOwner);
    }

    function testEmergencyRecoveryScenario() public {
        // Simulate compromised scenario - vault given to unknown router
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
        
        // Before giving to compromised router, ensure we can always recover
        // In real scenario, we would need the compromised router to have transfer_vault_ownership function
        // This test shows we maintain control as long as we control the vault directly
        assertEq(vaultV1.owner(), routerOwner, "Owner has direct control");
        
        vm.stopPrank();
    }

    function testVaultOwnershipWithThirdPartyRouter() public {
        // Deploy a third router that mimics RescueRouterV2
        vm.prank(routerOwner);
        IRescueRouter thirdRouter = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));
        
        // Transfer vault ownership through multiple routers
        vm.startPrank(routerOwner);
        
        // Get from original router
        rescueRouter.transfer_vault_ownership(routerOwner);
        
        // Give to third router
        vaultV1.transfer_owner(address(thirdRouter));
        assertEq(vaultV1.owner(), address(thirdRouter));
        
        // Recover from third router
        thirdRouter.transfer_vault_ownership(routerOwner);
        assertEq(vaultV1.owner(), routerOwner);
        
        vm.stopPrank();
    }

    function testOwnershipRecoveryPath() public {
        // This test documents the recovery path for vault ownership
        // Step 1: Router owner can always reclaim vault from any router they control
        vm.prank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
        
        // Step 2: Once owner has direct control, they can transfer to any address
        vm.prank(routerOwner);
        vaultV1.transfer_owner(routerOwner); // Could be any trusted address
        
        // Key insight: As long as we control the router contracts, we can always recover vault ownership
        assertEq(vaultV1.owner(), routerOwner, "Recovery successful");
    }
}
