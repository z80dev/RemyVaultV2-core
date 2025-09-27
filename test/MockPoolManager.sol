// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract MockPoolManager is IPoolManager {
    using BalanceDeltaLibrary for BalanceDelta;

    struct Donation {
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
        bytes data;
    }

    Donation[] public donations;

    function donationCount() external view returns (uint256) {
        return donations.length;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        returns (BalanceDelta)
    {
        donations.push(Donation({key: key, amount0: amount0, amount1: amount1, data: hookData}));
        return toBalanceDelta(0, 0);
    }

    // --- minimal stubs for unused interface functions ---
    function initialize(PoolKey memory, uint160) external pure override returns (int24) {
        revert("not implemented");
    }

    function unlock(bytes calldata) external pure override returns (bytes memory) {
        revert("not implemented");
    }

    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        override
        returns (BalanceDelta, BalanceDelta)
    {
        revert("not implemented");
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata)
        external
        pure
        override
        returns (BalanceDelta)
    {
        revert("not implemented");
    }

    function sync(Currency) external pure override {}

    function take(Currency, address, uint256) external pure override {
        revert("not implemented");
    }

    function settle() external payable override returns (uint256) {
        revert("not implemented");
    }

    function settleFor(address) external payable override returns (uint256) {
        revert("not implemented");
    }

    function clear(Currency, uint256) external pure override {
        revert("not implemented");
    }

    function mint(address, uint256, uint256) external pure override {
        revert("not implemented");
    }

    function burn(address, uint256, uint256) external pure override {
        revert("not implemented");
    }

    function updateDynamicLPFee(PoolKey memory, uint24) external pure override {
        revert("not implemented");
    }

    function protocolFeesAccrued(Currency) external pure override returns (uint256) {
        return 0;
    }

    function setProtocolFee(PoolKey memory, uint24) external pure override {
        revert("not implemented");
    }

    function setProtocolFeeController(address) external pure override {
        revert("not implemented");
    }

    function collectProtocolFees(address, Currency, uint256) external pure override returns (uint256) {
        revert("not implemented");
    }

    function protocolFeeController() external pure override returns (address) {
        return address(0);
    }

    function balanceOf(address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function allowance(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isOperator(address, address) external pure override returns (bool) {
        return false;
    }

    function transfer(address, uint256, uint256) external pure override returns (bool) {
        revert("not implemented");
    }

    function transferFrom(address, address, uint256, uint256) external pure override returns (bool) {
        revert("not implemented");
    }

    function approve(address, uint256, uint256) external pure override returns (bool) {
        revert("not implemented");
    }

    function setOperator(address, bool) external pure override returns (bool) {
        revert("not implemented");
    }

    function extsload(bytes32) external pure override returns (bytes32) {
        revert("not implemented");
    }

    function extsload(bytes32[] calldata) external pure override returns (bytes32[] memory) {
        revert("not implemented");
    }

    function extsload(bytes32, uint256) external pure override returns (bytes32[] memory) {
        revert("not implemented");
    }

    function exttload(bytes32) external pure override returns (bytes32) {
        revert("not implemented");
    }

    function exttload(bytes32[] calldata) external pure override returns (bytes32[] memory) {
        revert("not implemented");
    }
}
