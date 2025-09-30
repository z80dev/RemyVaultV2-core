// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultNFT} from "../src/RemyVaultNFT.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

contract RemyVaultFactoryTest is Test {
    RemyVaultFactory factory;
    MockERC721Simple collection;

    function setUp() public {
        factory = new RemyVaultFactory();
        collection = new MockERC721Simple("RemyVault", "REM");
    }

    function testDeployVaultRevertsOnDuplicateCollection() public {
        address firstVault = factory.deployVault(address(collection));
        assertEq(factory.vaultFor(address(collection)), firstVault);
        assertTrue(factory.isVault(firstVault));
        assertEq(collection.name(), "RemyVault");
        assertEq(collection.symbol(), "REM");
        assertEq(RemyVault(firstVault).name(), collection.name(), "vault should mirror collection name");
        assertEq(RemyVault(firstVault).symbol(), collection.symbol(), "vault should mirror collection symbol");

        vm.expectRevert(
            abi.encodeWithSelector(RemyVaultFactory.CollectionAlreadyDeployed.selector, address(collection))
        );
        factory.deployVault(address(collection));
    }

    function testDeployVaultRevertsOnZeroCollection() public {
        vm.expectRevert(RemyVaultFactory.CollectionAddressZero.selector);
        factory.deployVault(address(0));
    }

    function testDeployVaultRevertsWhenCollectionIsExistingVault() public {
        address firstVault = factory.deployVault(address(collection));

        vm.expectRevert(abi.encodeWithSelector(RemyVaultFactory.CollectionIsVault.selector, firstVault));
        factory.deployVault(firstVault);
    }

    function testPredictVaultAddressRevertsForExistingVault() public {
        address firstVault = factory.deployVault(address(collection));

        vm.expectRevert(abi.encodeWithSelector(RemyVaultFactory.CollectionIsVault.selector, firstVault));
        factory.predictVaultAddress(firstVault);
    }

    function testDeployDerivativeVaultPreMintsSupply() public {
        RemyVaultNFT derivativeCollection = new RemyVaultNFT("Derivative", "DRV", "ipfs://", address(this));
        address derivativeVault = factory.deployDerivativeVault(address(derivativeCollection), 5, bytes32(0));
        assertEq(factory.vaultFor(address(derivativeCollection)), derivativeVault, "vault mapping mismatch");
        assertTrue(factory.isVault(derivativeVault), "vault flag missing");

        MinterRemyVault vaultToken = MinterRemyVault(derivativeVault);
        uint256 expectedSupply = vaultToken.UNIT() * 5;
        assertEq(vaultToken.totalSupply(), expectedSupply, "supply mismatch");
        assertEq(vaultToken.balanceOf(address(this)), expectedSupply, "creator balance mismatch");
    }

    function testPredictDerivativeVaultAddressMatchesDeployment() public {
        RemyVaultNFT derivativeCollection = new RemyVaultNFT("Derivative", "DRV", "ipfs://", address(this));
        address predicted = factory.predictDerivativeVaultAddress(address(derivativeCollection), 1, bytes32(0));
        address deployed = factory.deployDerivativeVault(address(derivativeCollection), 1, bytes32(0));
        assertEq(predicted, deployed, "predicted address mismatch");
    }
}
