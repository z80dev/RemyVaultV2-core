// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import {IERC20} from "./IERC20.sol";

interface IManagedToken is IERC20 {
    function transfer_ownership(address newOwner) external;
    function mint(address to, uint256 amount) external;
}
