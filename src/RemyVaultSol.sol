// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC721} from "./interfaces/IERC721.sol";

contract RemyVaultSol is ERC20 {
    /// @notice Number of ERC20 tokens minted per deposited NFT.
    uint256 public constant UNIT = 1000 * 1e18;

    /// @dev Cached keccak256 hash of the token name for permit domain separation.
    bytes32 private immutable _nameHash;

    /// @dev EIP-712 version hash, matching the Vyper implementation's "1.0" domain.
    bytes32 private constant VERSION_HASH = keccak256("1.0");

    /// @notice The ERC721 collection held by the vault (unused until deposit logic is ported).
    IERC721 private immutable _erc721;

    /// @dev ERC20 metadata storage compatible with Solady's ERC20 base.
    string private _name;
    string private _symbol;

    /// @notice Emitted when NFTs are deposited into the vault.
    event Deposit(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);

    /// @notice Emitted when NFTs are withdrawn from the vault.
    event Withdraw(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);

    constructor(string memory name_, string memory symbol_, address erc721_) {
        _name = name_;
        _symbol = symbol_;
        _nameHash = keccak256(bytes(name_));
        _erc721 = IERC721(erc721_);
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

    function erc20() external view returns (address) {
        return address(this);
    }

    function erc721() public view returns (address) {
        return address(_erc721);
    }

    // -------------------------------------------------------------------------
    // ERC721 Accounting Helpers
    // -------------------------------------------------------------------------

    function quoteDeposit(uint256 count) external pure returns (uint256) {
        return UNIT * count;
    }

    function quoteWithdraw(uint256 count) external pure returns (uint256) {
        return UNIT * count;
    }

    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256 mintedAmount) {
        uint256 tokenCount = tokenIds.length;
        require(tokenCount != 0, "Must deposit at least one token");

        address receiver = recipient == address(0) ? msg.sender : recipient;
        IERC721 nft = _erc721;
        address sender = msg.sender;
        address vault = address(this);

        for (uint256 i = 0; i < tokenCount;) {
            nft.transferFrom(sender, vault, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        mintedAmount = tokenCount * UNIT;
        _mint(receiver, mintedAmount);

        emit Deposit(receiver, tokenIds, mintedAmount);
    }

    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256 burnedAmount) {
        uint256 tokenCount = tokenIds.length;
        require(tokenCount != 0, "Must withdraw at least one token");

        address receiver = recipient == address(0) ? msg.sender : recipient;
        burnedAmount = tokenCount * UNIT;

        _burn(msg.sender, burnedAmount);

        IERC721 nft = _erc721;
        for (uint256 i = 0; i < tokenCount;) {
            nft.safeTransferFrom(address(this), receiver, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit Withdraw(receiver, tokenIds, burnedAmount);
    }

    // -------------------------------------------------------------------------
    // Solady Overrides
    // -------------------------------------------------------------------------

    function _constantNameHash() internal view override returns (bytes32) {
        return _nameHash;
    }

    function _versionHash() internal pure override returns (bytes32) {
        return VERSION_HASH;
    }
}
