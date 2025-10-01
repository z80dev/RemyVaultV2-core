// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "./interfaces/IERC721.sol";
import {IERCXX} from "./interfaces/IERCXX.sol";
import {RemyVaultEIP712} from "./RemyVaultEIP712.sol";

contract RemyVault is RemyVaultEIP712, IERCXX {
    /// @notice Number of ERC20 tokens minted per deposited NFT.
    uint256 public constant UNIT = 1e18;

    /// @notice The ERC721 collection held by the vault (unused until deposit logic is ported).
    IERC721 private immutable ERC721_TOKEN;

    error ZeroCollectionAddress();

    constructor(address erc721_) RemyVaultEIP712(erc721_) {
        if (erc721_ == address(0)) revert ZeroCollectionAddress();
        ERC721_TOKEN = IERC721(erc721_);
    }

    // -------------------------------------------------------------------------
    // Metadata
    // -------------------------------------------------------------------------

    function erc20() public view override returns (address) {
        return address(this);
    }

    function erc721() public view override returns (address) {
        return address(ERC721_TOKEN);
    }

    // -------------------------------------------------------------------------
    // ERC721 Accounting Helpers
    // -------------------------------------------------------------------------

    function quoteDeposit(uint256 count) external pure override returns (uint256) {
        return UNIT * count;
    }

    function quoteWithdraw(uint256 count) external pure override returns (uint256) {
        return UNIT * count;
    }

    function deposit(uint256[] calldata tokenIds, address recipient) external override returns (uint256 mintedAmount) {
        uint256 tokenCount = tokenIds.length;
        require(tokenCount != 0, "Must deposit at least one token");

        address receiver = recipient == address(0) ? msg.sender : recipient;
        IERC721 nft = ERC721_TOKEN;
        address sender = msg.sender;
        address vault = address(this);

        for (uint256 i = 0; i < tokenCount;) {
            nft.safeTransferFrom(sender, vault, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        mintedAmount = tokenCount * UNIT;
        _mint(receiver, mintedAmount);

        emit Deposit(receiver, tokenIds, mintedAmount);
    }

    function withdraw(uint256[] calldata tokenIds, address recipient)
        external
        override
        returns (uint256 burnedAmount)
    {
        uint256 tokenCount = tokenIds.length;
        require(tokenCount != 0, "Must withdraw at least one token");

        address receiver = recipient == address(0) ? msg.sender : recipient;
        burnedAmount = tokenCount * UNIT;

        _burn(msg.sender, burnedAmount);

        IERC721 nft = ERC721_TOKEN;
        for (uint256 i = 0; i < tokenCount;) {
            nft.safeTransferFrom(address(this), receiver, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit Withdraw(receiver, tokenIds, burnedAmount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
