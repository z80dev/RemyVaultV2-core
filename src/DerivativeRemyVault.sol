// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC721} from "./interfaces/IERC721.sol";
import {IERCXX} from "./interfaces/IERCXX.sol";
import {RemyVaultNFT} from "./RemyVaultNFT.sol";

contract DerivativeRemyVault is ERC20, IERCXX {
    /// @notice Number of ERC20 tokens minted per deposited NFT.
    uint256 public constant UNIT = 1e18;

    /// @dev Cached keccak256 hash of the token name for permit domain separation.
    bytes32 private immutable NAME_HASH;

    /// @dev EIP-712 version hash, matching the legacy "1.0" domain.
    bytes32 private constant VERSION_HASH = keccak256("1.0");

    /// @notice The ERC721 collection managed by the vault.
    IERC721 private immutable ERC721_TOKEN;

    /// @dev Strongly-typed interface for minting derivative NFTs.
    RemyVaultNFT private immutable DERIVATIVE_NFT;

    /// @dev ERC20 metadata storage compatible with Solady's ERC20 base.
    string private _name;
    string private _symbol;

    /// @notice Maximum number of NFTs that can be minted via this vault.
    uint256 public immutable maxSupply;

    /// @notice Number of NFTs minted through the vault so far.
    uint256 public mintedCount;

    error MintZeroCount();
    error MintLimitExceeded();
    error RecipientZero();
    error SupplyOverflow();

    event DerivativeMint(address indexed account, uint256 count, uint256[] tokenIds);

    constructor(string memory name_, string memory symbol_, address erc721_, uint256 maxSupply_) {
        _name = name_;
        _symbol = symbol_;
        NAME_HASH = keccak256(bytes(name_));
        ERC721_TOKEN = IERC721(erc721_);
        DERIVATIVE_NFT = RemyVaultNFT(erc721_);
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
    // Metadata
    // -------------------------------------------------------------------------

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

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

    // -------------------------------------------------------------------------
    // Derivative Minting
    // -------------------------------------------------------------------------

    function mintWithTokens(uint256 count, address recipient) external returns (uint256[] memory tokenIds) {
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

    // -------------------------------------------------------------------------
    // Solady Overrides
    // -------------------------------------------------------------------------

    function _constantNameHash() internal view override returns (bytes32) {
        return NAME_HASH;
    }

    function _versionHash() internal pure override returns (bytes32) {
        return VERSION_HASH;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
