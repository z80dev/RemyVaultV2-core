// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";

import {DeployProtocol} from "../scripts/DeployProtocol.s.sol";
import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Vm} from "forge-std/Vm.sol";

contract DeployProtocolIntegrationTest is BaseTest {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address internal constant DEPLOYER = 0x70f4b83795Af9236dA8211CDa3b031E503C00970;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    function setUp() public override {
        super.setUp();
        vm.deal(DEPLOYER, 100 ether);
    }

    function testDeploymentScriptFlow_OnBaseFork() public {
        bytes memory hookArgs = abi.encode(POOL_MANAGER, DEPLOYER);
        (address expectedHook,) = HookMiner.find(DEPLOYER, HOOK_FLAGS, type(RemyVaultHook).creationCode, hookArgs);

        uint256 nonceBefore = vm.getNonce(DEPLOYER);
        address expectedVaultFactory = vm.computeCreateAddress(DEPLOYER, nonceBefore + 1);
        address expectedDerivativeFactory = vm.computeCreateAddress(DEPLOYER, nonceBefore + 2);

        require(expectedHook.code.length == 0, "hook pre-existing");
        require(expectedVaultFactory.code.length == 0, "vault factory pre-existing");
        require(expectedDerivativeFactory.code.length == 0, "derivative factory pre-existing");

        DeployProtocol script = new DeployProtocol();
        script.run();

        RemyVaultHook hook = RemyVaultHook(expectedHook);
        RemyVaultFactory vaultFactory = RemyVaultFactory(expectedVaultFactory);
        DerivativeFactory derivativeFactory = DerivativeFactory(expectedDerivativeFactory);

        assertEq(address(hook.poolManager()), address(POOL_MANAGER), "hook pool manager mismatch");
        assertEq(hook.owner(), address(derivativeFactory), "hook owner should be derivative factory");

        assertEq(address(derivativeFactory.VAULT_FACTORY()), address(vaultFactory), "factory wiring");
        assertEq(address(derivativeFactory.HOOK()), address(hook), "hook wiring");
        assertEq(address(derivativeFactory.POOL_MANAGER()), address(POOL_MANAGER), "pool manager wiring");

        uint256 nonceAfter = vm.getNonce(DEPLOYER);
        assertEq(nonceAfter, nonceBefore + 3, "unexpected deployer nonce delta");
    }
}
