// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";

abstract contract BaseTest is Test {

    string baseRpcUrl = vm.envString("BASE_RPC_URL");
    uint256 fork = vm.createSelectFork(baseRpcUrl);

}
