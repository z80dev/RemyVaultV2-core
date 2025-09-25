// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";

contract RemyVaultFactoryTest is Test {
    RemyVaultFactory factory;
    address collection;

    function setUp() public {
        factory = new RemyVaultFactory();
        collection = makeAddr("collection");
    }

    function testDeployVaultRevertsOnDuplicateCollection() public {
        address firstVault = factory.deployVault(collection, "RemyVault", "REM");
        assertEq(factory.vaultFor(collection), firstVault);
        assertTrue(factory.isVault(firstVault));

        vm.expectRevert(abi.encodeWithSelector(RemyVaultFactory.CollectionAlreadyDeployed.selector, collection));
        factory.deployVault(collection, "RemyVault", "REM");
    }

    function testDeployVaultRevertsOnZeroCollection() public {
        vm.expectRevert(RemyVaultFactory.CollectionAddressZero.selector);
        factory.deployVault(address(0), "RemyVault", "REM");
    }

    function testDeployVaultRevertsWhenCollectionIsExistingVault() public {
        address firstVault = factory.deployVault(collection, "RemyVault", "REM");

        vm.expectRevert(abi.encodeWithSelector(RemyVaultFactory.CollectionIsVault.selector, firstVault));
        factory.deployVault(firstVault, "RemyVault", "REM");
    }

    function testPredictVaultAddressRevertsForExistingVault() public {
        address firstVault = factory.deployVault(collection, "RemyVault", "REM");

        vm.expectRevert(abi.encodeWithSelector(RemyVaultFactory.CollectionIsVault.selector, firstVault));
        factory.predictVaultAddress(firstVault, "RemyVault", "REM");
    }
}
