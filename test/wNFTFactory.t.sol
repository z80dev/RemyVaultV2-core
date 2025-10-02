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
        address firstVault = factory.create(address(collection));
        assertEq(factory.wNFTFor(address(collection)), firstVault);
        assertTrue(factory.iswNFT(firstVault));
        assertEq(collection.name(), "wNFT");
        assertEq(collection.symbol(), "REM");
        assertEq(wNFT(firstVault).name(), string.concat("Wrapped ", collection.name()), "vault should mirror collection name");
        assertEq(wNFT(firstVault).symbol(), string.concat("w", collection.symbol()), "vault should mirror collection symbol");

        vm.expectRevert(
            abi.encodeWithSelector(wNFTFactory.CollectionAlreadyDeployed.selector, address(collection))
        );
        factory.create(address(collection));
    }

    function testDeployVaultRevertsOnZeroCollection() public {
        vm.expectRevert(wNFTFactory.CollectionAddressZero.selector);
        factory.create(address(0));
    }

    function testDeployVaultRevertsWhenCollectionIsExistingVault() public {
        address firstVault = factory.create(address(collection));

        vm.expectRevert(abi.encodeWithSelector(wNFTFactory.CollectionIswNFT.selector, firstVault));
        factory.create(firstVault);
    }

    function testPredictVaultAddressRevertsForExistingVault() public {
        address firstVault = factory.create(address(collection));

        vm.expectRevert(abi.encodeWithSelector(wNFTFactory.CollectionIswNFT.selector, firstVault));
        factory.computeAddress(firstVault);
    }
}
