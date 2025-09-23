// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

interface IRescueRouter {
    function owner() external view returns (address);
    function vault_address() external view returns (address);
    function router_address() external view returns (address);
    function weth() external view returns (address);
    function v3router_address() external view returns (address);
    function erc4626_address() external view returns (address);
    function erc721_address() external view returns (address);
    function erc20_address() external view returns (address);

    function stake_inventory(address recipient, uint256[] calldata token_ids) external;
    function unstake_inventory(address recipient, uint256[] calldata token_ids) external;
    function swap_eth_for_nft_v3(uint256[] calldata tokenIds, address recipient) external payable;
    function swap_nft_for_eth_v3(uint256[] calldata tokenIds, uint256 min_out, address recipient) external;
    function quote_swap_in_tokens(uint256[] calldata tokenIds_in, uint256[] calldata tokenIds_out)
        external
        view
        returns (uint256);
    function swap(uint256[] calldata tokenIds_in, uint256[] calldata tokenIds_out, address recipient)
        external
        payable;
    function transfer_owner(address new_owner) external;
    function transfer_vault_ownership(address new_owner) external;

    // RescueRouterV2 specific functions
    function swap_tokens_for_nfts(uint256[] calldata tokenIds, address recipient) external;
    function quote_tokens_for_nfts(uint256[] calldata tokenIds) external view returns (uint256);
}
