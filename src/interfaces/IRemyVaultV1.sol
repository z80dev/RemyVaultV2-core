// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

interface IRemyVaultV1 {
    function owner() external view returns (address);
    function set_fee_exempt(address account, bool exempt) external;
    function transfer_owner(address new_owner) external;
}