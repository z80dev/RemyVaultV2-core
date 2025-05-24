// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

interface IMigrator {
    function get_token_balances() external view returns (uint256, uint256);
    function migrate() external;
}