// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVault} from "../src/RemyVault.sol";

contract RemyVaultFactoryInvariantTest is Test {
    string internal constant DEPLOY_NAME = "Remy Vault Token";
    string internal constant DEPLOY_SYMBOL = "REMY";

    RemyVaultFactory internal factory;
    FactoryHandler internal handler;

    function setUp() public {
        factory = new RemyVaultFactory();
        handler = new FactoryHandler(factory, DEPLOY_NAME, DEPLOY_SYMBOL);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.deployVault.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_registryConsistency() public view {
        uint256 count = handler.trackedCount();
        string memory name_ = handler.deploymentName();
        string memory symbol_ = handler.deploymentSymbol();

        for (uint256 i; i < count; ++i) {
            address collection = handler.collectionAt(i);
            address vault = handler.vaultAt(i);

            assertEq(factory.vaultFor(collection), vault, "vaultFor mapping drifted");
            assertTrue(factory.isVault(vault), "vault flag missing for deployed vault");
            assertFalse(factory.isVault(collection), "collection incorrectly flagged as vault");
            assertEq(factory.vaultFor(vault), address(0), "vault address reused as collection");
            assertEq(RemyVault(vault).erc721(), collection, "vault erc721 target mismatch");

            address predicted = factory.predictVaultAddress(collection, name_, symbol_);
            assertEq(predicted, vault, "predictVaultAddress no longer deterministic");
        }
    }
}

contract FactoryHandler {
    uint256 internal constant MAX_TRACKED = 32;

    RemyVaultFactory internal immutable factory;
    string internal name_;
    string internal symbol_;

    address[] internal collections;
    address[] internal vaults;

    constructor(RemyVaultFactory factory_, string memory name, string memory symbol) {
        factory = factory_;
        name_ = name;
        symbol_ = symbol;
    }

    function deployVault(uint160 seed) external {
        address collection = address(uint160(seed));
        if (collection == address(0)) return;
        if (factory.isVault(collection)) return;
        if (factory.vaultFor(collection) != address(0)) return;

        try factory.deployVault(collection, name_, symbol_) returns (address vault) {
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

    function deploymentName() external view returns (string memory) {
        return name_;
    }

    function deploymentSymbol() external view returns (string memory) {
        return symbol_;
    }
}
