// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

/**
 * @title SimulateDeploymentAddresses
 * @notice Utility script that previews the contract addresses produced by upcoming deployments.
 * @dev Works for both direct CREATE deployments (using the caller's nonce) and CreateX deployments
 *      that rely on the shared factory. Run with `forge script`/`uv run forge script` and either a
 *      PRIVATE_KEY or DEPLOYER environment variable set to the deployer address.
 */
contract SimulateDeploymentAddresses is Script {
    // CreateX factory address (same constant used across the repo)
    address public constant CREATEX_FACTORY = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    function run() external {
        preview();
    }

    function preview() public {
        address deployer = _resolveDeployer();
        uint64 deployerNonce = vm.getNonce(deployer);

        console2.log("=== CREATE deployments (deployer)");
        console2.log("deployer", deployer);
        console2.log("current nonce", deployerNonce);
        console2.log("next deployment #0", vm.computeCreateAddress(deployer, uint256(deployerNonce)));
        console2.log("next deployment #1", vm.computeCreateAddress(deployer, uint256(deployerNonce) + 1));

        uint64 factoryNonce = vm.getNonce(CREATEX_FACTORY);
        console2.log("\n=== CreateX deployments");
        console2.log("factory", CREATEX_FACTORY);
        console2.log("current nonce", factoryNonce);
        console2.log("next deployment #0", vm.computeCreateAddress(CREATEX_FACTORY, uint256(factoryNonce)));
        console2.log("next deployment #1", vm.computeCreateAddress(CREATEX_FACTORY, uint256(factoryNonce) + 1));
    }

    function _resolveDeployer() internal view returns (address) {
        address explicit = vm.envOr("DEPLOYER", address(0));
        if (explicit != address(0)) {
            return explicit;
        }

        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(privateKey != 0, "Simulate: set DEPLOYER or PRIVATE_KEY env var");
        return vm.addr(privateKey);
    }
}
