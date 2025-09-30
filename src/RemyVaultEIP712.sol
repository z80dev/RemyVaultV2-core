// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/tokens/ERC20.sol";
import {EIP712} from "solady/utils/EIP712.sol";

abstract contract RemyVaultEIP712 is ERC20, EIP712 {
    /// @dev Cached keccak256 hash of the token name for the permit domain separator.
    bytes32 private immutable NAME_HASH;

    /// @dev ERC20 metadata storage for the vault token.
    string internal _name;
    string internal _symbol;

    /// @dev Static EIP-712 version string and hash to match the Vyper implementation.
    string internal constant EIP712_VERSION = "1.0";
    bytes32 private constant VERSION_HASH = keccak256(bytes(EIP712_VERSION));

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        NAME_HASH = keccak256(bytes(name_));
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
}
