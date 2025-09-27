// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
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

    function testDeployDerivativeVaultPreMintsSupply() public {
        address derivativeVault = factory.deployDerivativeVault(collection, "Derivative", "DRV", 5);
        assertEq(factory.vaultFor(collection), derivativeVault, "vault mapping mismatch");
        assertTrue(factory.isVault(derivativeVault), "vault flag missing");

        MinterRemyVault vaultToken = MinterRemyVault(derivativeVault);
        uint256 expectedSupply = vaultToken.UNIT() * 5;
        assertEq(vaultToken.totalSupply(), expectedSupply, "supply mismatch");
        assertEq(vaultToken.balanceOf(address(this)), expectedSupply, "creator balance mismatch");
    }

    function testPredictDerivativeVaultAddressMatchesDeployment() public {
        address predicted = factory.predictDerivativeVaultAddress(collection, "Derivative", "DRV", 1);
        address deployed = factory.deployDerivativeVault(collection, "Derivative", "DRV", 1);
        assertEq(predicted, deployed, "predicted address mismatch");
    }
}
