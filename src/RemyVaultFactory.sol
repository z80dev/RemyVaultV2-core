// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DerivativeRemyVault} from "./DerivativeRemyVault.sol";
import {RemyVault} from "./RemyVault.sol";

/// @notice Deploys deterministic `RemyVault` instances keyed by ERC721 collection.
contract RemyVaultFactory {
    /// @dev Track deployed vault per collection to prevent duplicates.
    mapping(address => address) public vaultFor;

    /// @dev Record deployed vault addresses to block them from being re-used as collections.
    mapping(address => bool) public isVault;

    /// @notice Emitted when a new vault is deployed for an ERC721 collection.
    event VaultCreated(address indexed collection, address indexed vault);

    error CollectionAlreadyDeployed(address collection);
    error CollectionAddressZero();
    error CollectionIsVault(address vault);

    /// @notice Deploy a new vault for `collection` using `CREATE2` salt derived from the collection address.
    /// @dev Reverts if the collection already has an associated vault or the collection address is zero.
    function deployVault(address collection, string calldata name_, string calldata symbol_)
        external
        returns (address vault)
    {
        if (collection == address(0)) revert CollectionAddressZero();
        if (vaultFor[collection] != address(0)) revert CollectionAlreadyDeployed(collection);
        if (isVault[collection]) revert CollectionIsVault(collection);

        bytes32 salt = _salt(collection);
        vault = address(new RemyVault{salt: salt}(name_, symbol_, collection));

        vaultFor[collection] = vault;
        isVault[vault] = true;
        emit VaultCreated(collection, vault);
    }

    /// @notice Deploy a derivative vault that pre-mints its full token supply to the caller.
    function deployDerivativeVault(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply
    ) external returns (address vault) {
        if (collection == address(0)) revert CollectionAddressZero();
        if (vaultFor[collection] != address(0)) revert CollectionAlreadyDeployed(collection);
        if (isVault[collection]) revert CollectionIsVault(collection);

        bytes32 salt = _salt(collection);
        vault = address(new DerivativeRemyVault{salt: salt}(name_, symbol_, collection, maxSupply));

        uint256 mintedSupply = DerivativeRemyVault(vault).balanceOf(address(this));
        if (mintedSupply != 0) {
            DerivativeRemyVault(vault).transfer(msg.sender, mintedSupply);
        }

        vaultFor[collection] = vault;
        isVault[vault] = true;
        emit VaultCreated(collection, vault);
    }

    /// @notice Predict the vault address for the provided constructor arguments without deploying.
    function predictVaultAddress(address collection, string calldata name_, string calldata symbol_)
        external
        view
        returns (address)
    {
        if (collection == address(0)) revert CollectionAddressZero();
        if (isVault[collection]) revert CollectionIsVault(collection);

        bytes32 bytecodeHash =
            keccak256(abi.encodePacked(type(RemyVault).creationCode, abi.encode(name_, symbol_, collection)));
        return _computeCreate2Address(_salt(collection), bytecodeHash);
    }

    /// @notice Predict the address for a derivative vault without deploying.
    function predictDerivativeVaultAddress(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply
    ) external view returns (address) {
        if (collection == address(0)) revert CollectionAddressZero();
        if (isVault[collection]) revert CollectionIsVault(collection);

        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(DerivativeRemyVault).creationCode, abi.encode(name_, symbol_, collection, maxSupply))
        );
        return _computeCreate2Address(_salt(collection), bytecodeHash);
    }

    /// @notice Helper to derive the salt used for CREATE2 deployments.
    function _salt(address collection) private pure returns (bytes32) {
        return bytes32(uint256(uint160(collection)));
    }

    /// @notice Helper to compute the deterministic CREATE2 contract address.
    function _computeCreate2Address(bytes32 salt, bytes32 bytecodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
