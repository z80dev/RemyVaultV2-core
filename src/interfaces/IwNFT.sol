// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./IERC20.sol";

interface IwNFT is IERC20 {
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

    // ERC20 helper exposure
    function set_minter(address minter, bool status) external;
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}
