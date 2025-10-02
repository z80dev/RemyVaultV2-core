// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFT} from "../src/wNFT.sol";

/**
 * @notice Script that deploys the wNFTFactory contract.
 */
contract DeploywNFTFactory is Script {
    // Impersonated deployer used throughout the existing scripts/tests.
    address internal constant DEPLOYER = 0x70f4b83795Af9236dA8211CDa3b031E503C00970;
    bytes32 salt = keccak256("remyboysincontrol");

    function run() external {
        vm.startBroadcast();
        wNFTFactory factory = new wNFTFactory{salt: salt}();
        vm.stopBroadcast();

        console2.log("wNFTFactory deployed at", address(factory));
    }
}
