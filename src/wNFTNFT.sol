// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";

contract wNFTNFT is ERC721, Ownable {
    using LibString for uint256;

    event BaseUriSet(string baseUri);
    event TokenURISet(uint256 indexed tokenId, string tokenUri);
    event MinterUpdated(address indexed account, bool allowed);

    error NotMinter();
    error IndexOutOfBounds();
    error InvalidBatchLength();

    string private _name;
    string private _symbol;
    string private baseUriPrefix;

    uint256 private nextTokenId;

    mapping(address => bool) private _minters;
    mapping(uint256 => string) private tokenUris;

    uint256[] private _allTokens;
    mapping(uint256 => uint256) private _allTokensIndex;
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    constructor(string memory name_, string memory symbol_, string memory baseUri_, address owner_) {
        _name = name_;
        _symbol = symbol_;
        baseUriPrefix = baseUri_;
        address initialOwner = owner_ == address(0) ? msg.sender : owner_;
        _initializeOwner(initialOwner);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function baseUri() external view returns (string memory) {
        return baseUriPrefix;
    }

    function setBaseUri(string calldata newBaseUri) external onlyOwner {
        baseUriPrefix = newBaseUri;
        emit BaseUriSet(newBaseUri);
    }

    function setTokenUri(uint256 tokenId, string calldata tokenUriSuffix) external onlyOwner {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        if (bytes(tokenUriSuffix).length == 0) {
            if (bytes(tokenUris[tokenId]).length != 0) {
                delete tokenUris[tokenId];
            }
        } else {
            tokenUris[tokenId] = tokenUriSuffix;
        }
        emit TokenURISet(tokenId, tokenUriSuffix);
    }

    function setMinter(address account, bool allowed) public onlyOwner {
        _minters[account] = allowed;
        emit MinterUpdated(account, allowed);
    }

    function set_minter(address account, bool allowed) external {
        setMinter(account, allowed);
    }

    function isMinter(address account) public view returns (bool) {
        return _minters[account];
    }

    function is_minter(address account) external view returns (bool) {
        return isMinter(account);
    }

    function safeMint(address to, string calldata tokenUriSuffix) public returns (uint256 tokenId) {
        if (!_minters[msg.sender]) revert NotMinter();
        tokenId = _mintWithUri(to, tokenUriSuffix);
    }

    function safe_mint(address to, string calldata tokenUriSuffix) external returns (uint256) {
        return safeMint(to, tokenUriSuffix);
    }

    function batchMint(address to, uint256 amount, string[] calldata tokenUriSuffixes)
        public
        returns (uint256[] memory tokenIds)
    {
        if (!_minters[msg.sender]) revert NotMinter();
        if (amount == 0) revert InvalidBatchLength();
        if (tokenUriSuffixes.length != 0 && tokenUriSuffixes.length != amount) revert InvalidBatchLength();

        tokenIds = new uint256[](amount);
        if (tokenUriSuffixes.length == 0) {
            for (uint256 i; i < amount;) {
                tokenIds[i] = _mintWithUri(to, "");
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint256 i; i < amount;) {
                tokenIds[i] = _mintWithUri(to, tokenUriSuffixes[i]);
                unchecked {
                    ++i;
                }
            }
        }
    }

    function batch_mint(address to, uint256 amount, string[] calldata tokenUriSuffixes)
        external
        returns (uint256[] memory)
    {
        return batchMint(to, amount, tokenUriSuffixes);
    }

    function burn(uint256 tokenId) external {
        _burn(msg.sender, tokenId);
    }

    function batchBurn(uint256[] calldata tokenIds) public {
        uint256 length = tokenIds.length;
        if (length == 0) revert InvalidBatchLength();
        for (uint256 i; i < length;) {
            _burn(msg.sender, tokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    function batch_burn(uint256[] calldata tokenIds) external {
        batchBurn(tokenIds);
    }

    function totalSupply() external view returns (uint256) {
        return _allTokens.length;
    }

    function tokenByIndex(uint256 index) external view returns (uint256) {
        if (index >= _allTokens.length) revert IndexOutOfBounds();
        return _allTokens[index];
    }

    function tokenOfOwnerByIndex(address owner_, uint256 index) external view returns (uint256) {
        if (index >= balanceOf(owner_)) revert IndexOutOfBounds();
        return _ownedTokens[owner_][index];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        string memory suffix = tokenUris[tokenId];
        if (bytes(suffix).length != 0) {
            return string.concat(baseUriPrefix, suffix);
        }
        if (bytes(baseUriPrefix).length == 0) {
            return tokenId.toString();
        }
        return string.concat(baseUriPrefix, tokenId.toString());
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x780e9d63 || super.supportsInterface(interfaceId);
    }

    function transfer_ownership(address newOwner) external onlyOwner {
        transferOwnership(newOwner);
    }

    function renounce_ownership() external onlyOwner {
        renounceOwnership();
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        if (from == address(0)) {
            _addTokenToAllTokensEnumeration(tokenId);
        } else if (from != to) {
            _removeTokenFromOwnerEnumeration(from, tokenId);
        }

        if (to == address(0)) {
            _removeTokenFromAllTokensEnumeration(tokenId);
        } else if (to != from) {
            _addTokenToOwnerEnumeration(to, tokenId);
        }
    }

    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        uint256 length = balanceOf(to);
        _ownedTokens[to][length] = tokenId;
        _ownedTokensIndex[tokenId] = length;
    }

    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        _allTokensIndex[tokenId] = _allTokens.length;
        _allTokens.push(tokenId);
    }

    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        uint256 lastTokenIndex = balanceOf(from) - 1;
        uint256 tokenIndex = _ownedTokensIndex[tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastTokenIndex];
            _ownedTokens[from][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }

        delete _ownedTokensIndex[tokenId];
        delete _ownedTokens[from][lastTokenIndex];
    }

    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        uint256 lastTokenIndex = _allTokens.length - 1;
        uint256 tokenIndex = _allTokensIndex[tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _allTokens[lastTokenIndex];
            _allTokens[tokenIndex] = lastTokenId;
            _allTokensIndex[lastTokenId] = tokenIndex;
        }

        _allTokens.pop();
        delete _allTokensIndex[tokenId];
        if (bytes(tokenUris[tokenId]).length != 0) {
            delete tokenUris[tokenId];
        }
    }

    function _mintWithUri(address to, string memory tokenUriSuffix) private returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        if (bytes(tokenUriSuffix).length != 0) {
            tokenUris[tokenId] = tokenUriSuffix;
            emit TokenURISet(tokenId, tokenUriSuffix);
        }
    }
}
