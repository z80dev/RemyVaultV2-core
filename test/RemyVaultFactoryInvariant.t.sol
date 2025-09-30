// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

contract RemyVaultFactoryInvariantTest is Test {
    RemyVaultFactory internal factory;
    FactoryHandler internal handler;

    function setUp() public {
        factory = new RemyVaultFactory();
        handler = new FactoryHandler(factory);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.deployVault.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_registryConsistency() public view {
        uint256 count = handler.trackedCount();

        for (uint256 i; i < count; ++i) {
            address collection = handler.collectionAt(i);
            address vault = handler.vaultAt(i);

            assertEq(factory.vaultFor(collection), vault, "vaultFor mapping drifted");
            assertTrue(factory.isVault(vault), "vault flag missing for deployed vault");
            assertFalse(factory.isVault(collection), "collection incorrectly flagged as vault");
            assertEq(factory.vaultFor(vault), address(0), "vault address reused as collection");
            assertEq(RemyVault(vault).erc721(), collection, "vault erc721 target mismatch");

            address predicted = factory.computeAddress(collection);
            assertEq(predicted, vault, "computeAddress no longer deterministic");
        }
    }
}

contract FactoryHandler {
    uint256 internal constant MAX_TRACKED = 32;

    RemyVaultFactory internal immutable factory;

    address[] internal collections;
    address[] internal vaults;
    mapping(uint160 => address) internal knownCollections;

    constructor(RemyVaultFactory factory_) {
        factory = factory_;
    }

    function deployVault(uint160 seed) external {
        address collection = knownCollections[seed];
        if (collection == address(0)) {
            collection = address(new MockERC721Simple("Invariant NFT", "INVT"));
            knownCollections[seed] = collection;
        }
        if (factory.isVault(collection)) return;
        if (factory.vaultFor(collection) != address(0)) return;

        try factory.deployVault(collection) returns (address vault) {
            if (collections.length < MAX_TRACKED) {
                collections.push(collection);
                vaults.push(vault);
            }
        } catch {}
    }

    function trackedCount() external view returns (uint256) {
        return collections.length;
    }

    function collectionAt(uint256 index) external view returns (address) {
        return collections[index];
    }

    function vaultAt(uint256 index) external view returns (address) {
        return vaults[index];
    }
}
