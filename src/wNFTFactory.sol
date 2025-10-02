// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {wNFT} from "./wNFT.sol";

/// @notice Deploys deterministic `wNFT` instances keyed by ERC721 collection.
contract wNFTFactory {
    /// @dev Track deployed vault per collection to prevent duplicates.
    mapping(address => address) public wNFTFor;

    /// @dev Record deployed wNFT addresses to block them from being re-used as collections.
    mapping(address => bool) public iswNFT;

    /// @notice Emitted when a new wNFT is deployed for an ERC721 collection.
    event wNFTCreated(address indexed collection, address indexed wNFT);

    error CollectionAlreadyDeployed(address collection);
    error CollectionAddressZero();
    error CollectionIswNFT(address wNFT);

    /// @notice Deploy a new wNFT for `collection` using `CREATE2` salt derived from the collection address.
    /// @dev Reverts if the collection already has an associated wNFT or the collection address is zero.
    function create(address collection) external returns (address wNFTAddr) {
        if (collection == address(0)) revert CollectionAddressZero();
        if (wNFTFor[collection] != address(0)) revert CollectionAlreadyDeployed(collection);
        if (iswNFT[collection]) revert CollectionIswNFT(collection);

        bytes32 salt = _salt(collection);
        wNFTAddr = address(new wNFT{salt: salt}(collection));

        wNFTFor[collection] = wNFTAddr;
        iswNFT[wNFTAddr] = true;
        emit wNFTCreated(collection, wNFTAddr);
    }

    /// @notice Compute the wNFT address for the provided constructor arguments without deploying.
    function computeAddress(address collection) external view returns (address) {
        if (collection == address(0)) revert CollectionAddressZero();
        if (iswNFT[collection]) revert CollectionIswNFT(collection);

        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(wNFT).creationCode, abi.encode(collection)));
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
