// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {wNFT} from "../src/wNFT.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFTNFT} from "../src/wNFTNFT.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

contract RemyVaultFactoryTest is Test {
    wNFTFactory factory;
    MockERC721Simple collection;

    function setUp() public {
        factory = new wNFTFactory();
        collection = new MockERC721Simple("wNFT", "REM");
    }

    function testDeployVaultRevertsOnDuplicateCollection() public {
        address firstVault = factory.deployVault(address(collection));
        assertEq(factory.vaultFor(address(collection)), firstVault);
        assertTrue(factory.isVault(firstVault));
        assertEq(collection.name(), "wNFT");
        assertEq(collection.symbol(), "REM");
        assertEq(wNFT(firstVault).name(), collection.name(), "vault should mirror collection name");
        assertEq(wNFT(firstVault).symbol(), collection.symbol(), "vault should mirror collection symbol");

        vm.expectRevert(
            abi.encodeWithSelector(wNFTFactory.CollectionAlreadyDeployed.selector, address(collection))
        );
        factory.deployVault(address(collection));
    }

    function testDeployVaultRevertsOnZeroCollection() public {
        vm.expectRevert(wNFTFactory.CollectionAddressZero.selector);
        factory.deployVault(address(0));
    }

    function testDeployVaultRevertsWhenCollectionIsExistingVault() public {
        address firstVault = factory.deployVault(address(collection));

        vm.expectRevert(abi.encodeWithSelector(wNFTFactory.CollectionIsVault.selector, firstVault));
        factory.deployVault(firstVault);
    }

    function testPredictVaultAddressRevertsForExistingVault() public {
        address firstVault = factory.deployVault(address(collection));

        vm.expectRevert(abi.encodeWithSelector(wNFTFactory.CollectionIsVault.selector, firstVault));
        factory.computeAddress(firstVault);
    }

    function testDeployDerivativeVaultPreMintsSupply() public {
        wNFTNFT derivativeCollection = new wNFTNFT("Derivative", "DRV", "ipfs://", address(this));
        address derivativeVault = factory.deployDerivativeVault(address(derivativeCollection), 5, bytes32(0));
        assertEq(factory.vaultFor(address(derivativeCollection)), derivativeVault, "vault mapping mismatch");
        assertTrue(factory.isVault(derivativeVault), "vault flag missing");

        wNFTMinter vaultToken = wNFTMinter(derivativeVault);
        uint256 expectedSupply = vaultToken.UNIT() * 5;
        assertEq(vaultToken.totalSupply(), expectedSupply, "supply mismatch");
        assertEq(vaultToken.balanceOf(address(this)), expectedSupply, "creator balance mismatch");
    }

    function testPredictDerivativeVaultAddressMatchesDeployment() public {
        wNFTNFT derivativeCollection = new wNFTNFT("Derivative", "DRV", "ipfs://", address(this));
        address predicted = factory.computeDerivativeAddress(address(derivativeCollection), 1, bytes32(0));
        address deployed = factory.deployDerivativeVault(address(derivativeCollection), 1, bytes32(0));
        assertEq(predicted, deployed, "predicted address mismatch");
    }

    function testDeployMultipleDerivativesForSameParent() public {
        // Deploy first derivative
        wNFTNFT derivative1 = new wNFTNFT("Derivative 1", "DRV1", "ipfs://1/", address(this));
        address vault1 = factory.deployDerivativeVault(address(derivative1), 10, bytes32(0));

        // Deploy second derivative for the same parent collection
        wNFTNFT derivative2 = new wNFTNFT("Derivative 2", "DRV2", "ipfs://2/", address(this));
        address vault2 = factory.deployDerivativeVault(address(derivative2), 20, bytes32(0));

        // Verify both vaults are correctly mapped
        assertEq(factory.vaultFor(address(derivative1)), vault1, "first vault mapping mismatch");
        assertEq(factory.vaultFor(address(derivative2)), vault2, "second vault mapping mismatch");

        // Verify vaults are different
        assertTrue(vault1 != vault2, "vaults should be different");

        // Verify both are recognized as vaults
        assertTrue(factory.isVault(vault1), "first vault not recognized");
        assertTrue(factory.isVault(vault2), "second vault not recognized");

        // Verify supplies are correct
        assertEq(wNFTMinter(vault1).totalSupply(), 10 * wNFTMinter(vault1).UNIT(), "first vault supply mismatch");
        assertEq(wNFTMinter(vault2).totalSupply(), 20 * wNFTMinter(vault2).UNIT(), "second vault supply mismatch");
    }
}
