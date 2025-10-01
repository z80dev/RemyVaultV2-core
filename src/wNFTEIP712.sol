// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/tokens/ERC20.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibString} from "solady/utils/LibString.sol";
import {IERC721Metadata} from "./interfaces/IERC721Metadata.sol";

abstract contract wNFTEIP712 is ERC20, EIP712 {
    /// @dev Cached keccak256 hash of the token name for the permit domain separator.
    bytes32 private immutable NAME_HASH;

    /// @dev ERC20 metadata storage for the vault token.
    string internal _name;
    string internal _symbol;

    /// @dev Static EIP-712 version string and hash to match the Vyper implementation.
    string internal constant EIP712_VERSION = "1.0";
    bytes32 private constant VERSION_HASH = keccak256(bytes(EIP712_VERSION));

    error MetadataQueryFailed(address token);

    constructor(address erc721_) {
        _name = LibString.concat("Wrapped ", _queryName(erc721_));
        _symbol = LibString.concat("w", _querySymbol(erc721_));
        NAME_HASH = keccak256(bytes(_name));
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function _constantNameHash() internal view override returns (bytes32) {
        return NAME_HASH;
    }

    function _versionHash() internal pure override returns (bytes32) {
        return VERSION_HASH;
    }

    function _domainNameAndVersion() internal view override returns (string memory name_, string memory version_) {
        name_ = _name;
        version_ = EIP712_VERSION;
    }

    function _domainNameAndVersionMayChange() internal pure override returns (bool) {
        // Domain values are immutable, but returning true delays caching until after
        // constructor storage writes complete.
        return true;
    }

    function _queryName(address token) private view returns (string memory name_) {
        name_ = _staticcallString(token, IERC721Metadata.name.selector);
    }

    function _querySymbol(address token) private view returns (string memory symbol_) {
        symbol_ = _staticcallString(token, IERC721Metadata.symbol.selector);
    }

    function _staticcallString(address token, bytes4 selector) private view returns (string memory value) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(selector));
        if (!success || data.length == 0) revert MetadataQueryFailed(token);
        value = abi.decode(data, (string));
    }
}
