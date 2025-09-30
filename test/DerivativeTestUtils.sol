// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DerivativeFactory} from "../src/DerivativeFactory.sol";

/// @notice Test utilities for derivative vault address prediction and salt mining
abstract contract DerivativeTestUtils is Test {
    /// @notice Predict the derivative vault address for given parameters and salt
    /// @param factory The DerivativeFactory instance
    /// @param nftAddress The address of the derivative NFT collection
    /// @param vaultName The name for the derivative vault token
    /// @param vaultSymbol The symbol for the derivative vault token
    /// @param maxSupply The maximum supply of derivative NFTs
    /// @param salt The salt for CREATE2 deployment
    /// @return The predicted address of the derivative vault
    function predictDerivativeAddress(
        DerivativeFactory factory,
        address nftAddress,
        string memory vaultName,
        string memory vaultSymbol,
        uint256 maxSupply,
        bytes32 salt
    ) internal view returns (address) {
        return factory.predictDerivativeVaultAddress(nftAddress, vaultName, vaultSymbol, maxSupply, salt);
    }

    /// @notice Predict both the NFT and vault addresses for a derivative deployment
    /// @param factory The DerivativeFactory instance
    /// @param vaultName The name for the derivative vault token
    /// @param vaultSymbol The symbol for the derivative vault token
    /// @param maxSupply The maximum supply of derivative NFTs
    /// @param salt The salt for CREATE2 deployment
    /// @return nftAddress The predicted address of the NFT collection
    /// @return vaultAddress The predicted address of the derivative vault
    function predictDerivativeAddresses(
        DerivativeFactory factory,
        string memory vaultName,
        string memory vaultSymbol,
        uint256 maxSupply,
        bytes32 salt
    ) internal view returns (address nftAddress, address vaultAddress) {
        // The NFT is created using CREATE (not CREATE2) in createDerivative
        // So we need to predict the NFT address based on the factory's nonce
        uint64 factoryNonce = vm.getNonce(address(factory));
        nftAddress = _computeCreateAddress(address(factory), factoryNonce);

        // Predict the vault address using CREATE2
        vaultAddress = factory.predictDerivativeVaultAddress(nftAddress, vaultName, vaultSymbol, maxSupply, salt);
    }

    /// @notice Mine a salt that ensures the derivative vault address > target token address
    /// @dev This ensures the derivative will be token1 in a Uniswap pool against the target token
    /// @param factory The DerivativeFactory instance
    /// @param targetToken The address of the token to compare against (e.g., parent vault)
    /// @param vaultName The name for the derivative vault token
    /// @param vaultSymbol The symbol for the derivative vault token
    /// @param maxSupply The maximum supply of derivative NFTs
    /// @param maxIterations Maximum number of salts to try (default: 10000)
    /// @return salt The mined salt that ensures derivative > targetToken
    function mineSaltForToken1(
        DerivativeFactory factory,
        address targetToken,
        string memory vaultName,
        string memory vaultSymbol,
        uint256 maxSupply,
        uint256 maxIterations
    ) internal view returns (bytes32 salt) {
        // Predict the NFT address based on factory's current nonce
        uint64 factoryNonce = vm.getNonce(address(factory));
        address predictedNFT = _computeCreateAddress(address(factory), factoryNonce);

        // Mine a salt such that the derivative vault address > target token address
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            address predictedVault =
                factory.predictDerivativeVaultAddress(predictedNFT, vaultName, vaultSymbol, maxSupply, salt);

            if (predictedVault > targetToken) {
                return salt;
            }
        }

        revert("Could not find valid salt in specified iterations");
    }

    /// @notice Mine a salt that ensures the derivative vault address > target token address
    /// @dev Convenience overload with default maxIterations = 10000
    function mineSaltForToken1(
        DerivativeFactory factory,
        address targetToken,
        string memory vaultName,
        string memory vaultSymbol,
        uint256 maxSupply
    ) internal view returns (bytes32) {
        return mineSaltForToken1(factory, targetToken, vaultName, vaultSymbol, maxSupply, 10000);
    }

    /// @notice Compute the address of a contract deployed with CREATE
    /// @param deployer The address that will deploy the contract
    /// @param nonce The nonce of the deployer at deployment time
    /// @return The predicted CREATE address
    function _computeCreateAddress(address deployer, uint64 nonce) internal pure returns (address) {
        // RLP encoding of [deployer, nonce]
        bytes memory rlpEncoded;

        if (nonce == 0x00) {
            rlpEncoded = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            rlpEncoded = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)));
        } else if (nonce <= 0xff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), bytes1(uint8(nonce)));
        } else if (nonce <= 0xffff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), bytes2(uint16(nonce)));
        } else if (nonce <= 0xffffff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), bytes3(uint24(nonce)));
        } else {
            rlpEncoded = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), bytes4(uint32(nonce)));
        }

        return address(uint160(uint256(keccak256(rlpEncoded))));
    }
}