// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {wNFT} from "../src/wNFT.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
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
        assertEq(wNFT(firstVault).name(), string.concat("Wrapped ", collection.name()), "vault should mirror collection name");
        assertEq(wNFT(firstVault).symbol(), string.concat("w", collection.symbol()), "vault should mirror collection symbol");

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
}
