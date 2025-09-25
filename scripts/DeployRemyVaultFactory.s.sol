// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface ICreateX {
    function deployCreate2(bytes calldata initCode, bytes32 salt) external payable returns (address newContract);
}

/**
 * @notice Script that deploys the RemyVaultFactory via the shared CreateX factory, using a configurable salt.
 */
contract DeployRemyVaultFactory is Script {
    address public constant CREATEX_FACTORY = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @dev Set the salt via env var `SALT` (raw string automatically keccak'd) or `SALT_HEX` for explicit bytes32.
    function run() external {
        bytes32 salt = _resolveSalt();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console2.log("deployer", deployer);
        console2.log("salt", salt);

        bytes memory initCode = _factoryInitCode();
        console2.log("init code hash", keccak256(initCode));
        console2.log("predicted address", _predictAddress(initCode, salt));

        vm.startBroadcast(deployerKey);
        address deployed = ICreateX(CREATEX_FACTORY).deployCreate2(initCode, salt);
        vm.stopBroadcast();

        console2.log("RemyVaultFactory deployed at", deployed);
    }

    function _factoryInitCode() internal view returns (bytes memory) {
        bytes memory creation = vm.getCode("RemyVaultFactory.sol:RemyVaultFactory");
        require(creation.length != 0, "init code empty");
        return creation;
    }

    function _resolveSalt() internal view returns (bytes32) {
        string memory saltString = vm.envOr("SALT", string(""));
        if (bytes(saltString).length != 0) {
            return keccak256(bytes(saltString));
        }

        bytes32 rawSalt = vm.envOr("SALT_HEX", bytes32(0));
        require(rawSalt != bytes32(0), "set SALT or SALT_HEX env var");
        return rawSalt;
    }

    function _predictAddress(bytes memory initCode, bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATEX_FACTORY, salt, keccak256(initCode))))));
    }
}

