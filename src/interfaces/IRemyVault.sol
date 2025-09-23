// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRemyVault {
    // Events
    event Deposit(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);
    event Withdraw(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);

    // View functions
    function erc20() external view returns (address);
    function erc721() external view returns (address);
    function quoteDeposit(uint256 count) external pure returns (uint256);
    function quoteWithdraw(uint256 count) external pure returns (uint256);

    // State-changing functions
    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
}
