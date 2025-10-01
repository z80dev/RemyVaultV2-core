// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {wNFT} from "./wNFT.sol";
import {wNFTNFT} from "./wNFTNFT.sol";

contract wNFTMinter is wNFT {
    /// @dev Strongly-typed interface for minting derivative NFTs.
    wNFTNFT private immutable DERIVATIVE_NFT;

    /// @notice Maximum number of NFTs that can be minted via this vault.
    uint256 public immutable maxSupply;

    /// @notice Number of NFTs minted through the vault so far.
    uint256 public mintedCount;

    error MintZeroCount();
    error MintLimitExceeded();
    error RecipientZero();
    error SupplyOverflow();

    event DerivativeMint(address indexed account, uint256 count, uint256[] tokenIds);

    constructor(address erc721_, uint256 maxSupply_) wNFT(erc721_) {
        DERIVATIVE_NFT = wNFTNFT(erc721_);
        maxSupply = maxSupply_;

        if (maxSupply_ != 0 && maxSupply_ > type(uint256).max / UNIT) {
            revert SupplyOverflow();
        }

        uint256 initialSupply = maxSupply_ * UNIT;
        if (initialSupply != 0) {
            _mint(msg.sender, initialSupply);
        }
    }
    // -------------------------------------------------------------------------
    // Derivative Minting
    // -------------------------------------------------------------------------

    function mint(uint256 count, address recipient) external returns (uint256[] memory tokenIds) {
        if (count == 0) revert MintZeroCount();
        if (recipient == address(0)) revert RecipientZero();

        uint256 newMinted = mintedCount + count;
        if (maxSupply != 0 && newMinted > maxSupply) revert MintLimitExceeded();
        mintedCount = newMinted;

        uint256 cost = count * UNIT;
        _burn(msg.sender, cost);

        tokenIds = DERIVATIVE_NFT.batchMint(recipient, count, new string[](0));
        emit DerivativeMint(recipient, count, tokenIds);
    }
}
