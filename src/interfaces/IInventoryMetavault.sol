// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInventoryMetavault {
    // Events
    event NftContractAdded(address indexed nft_contract);
    event NftContractRemoved(address indexed nft_contract);
    event InventoryDeposit(address indexed user, address indexed nft_contract, uint256[] token_ids, uint256 shares_minted);
    event InventoryWithdraw(address indexed user, address indexed nft_contract, uint256[] token_ids, uint256 shares_burned);
    event InventoryPurchase(address indexed buyer, address indexed nft_contract, uint256[] token_ids, uint256 vault_tokens_paid);

    // View functions
    function remy_vault() external view returns (address);
    function vault_erc20() external view returns (address);
    function shares_token() external view returns (address);
    function owner() external view returns (address);
    function quote_purchase(address nft_contract, uint256 count) external view returns (uint256);
    function get_available_inventory(address nft_contract) external view returns (uint256);
    function is_supported_contract(address nft_contract) external view returns (bool);

    // Admin functions
    function add_nft_contract(address nft_contract) external;
    function remove_nft_contract(address nft_contract) external;
    function transfer_ownership(address new_owner) external;

    // User functions
    function deposit_nfts(address nft_contract, uint256[] calldata token_ids) external returns (uint256);
    function withdraw_nfts(address nft_contract, uint256[] calldata token_ids) external returns (uint256);
    function purchase_nfts(address nft_contract, uint256[] calldata token_ids) external returns (uint256);
    function onERC721Received(address operator, address from_address, uint256 token_id, bytes calldata data) external returns (bytes4);
}