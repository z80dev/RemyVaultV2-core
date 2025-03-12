// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IInventoryMetavault
 * @dev Interface for the InventoryMetavault contract
 */
interface IInventoryMetavault {
    // Events
    event InventoryDeposit(address indexed user, uint256[] token_ids, uint256 shares_minted);
    event InventoryWithdraw(address indexed user, uint256[] token_ids, uint256 shares_burned);
    event InventoryPurchase(address indexed buyer, uint256[] token_ids, uint256 vault_tokens_paid);
    event TokenRegistered(uint256 indexed token_id);
    event LiquidityAlert(uint256 current_liquidity_bps, uint256 needed_tokens, uint256 available_tokens);

    // Core references
    function remy_vault() external view returns (address);
    function nft_collection() external view returns (address);
    function internal_token() external view returns (address);
    function staking_vault() external view returns (address);

    // Constants
    function MARKUP_BPS() external view returns (uint256);
    function LIQUIDITY_THRESHOLD_BPS() external view returns (uint256);

    // State variables
    function inventory_count() external view returns (uint256);
    function paused() external view returns (bool);
    function owner() external view returns (address);

    // Core deposit functions
    function deposit(uint256[] calldata token_ids, address receiver) external returns (uint256);
    function deposit_remy_tokens(uint256 amount, address receiver) external returns (uint256);

    // Core withdrawal functions
    function withdraw(uint256[] calldata token_ids, address receiver) external returns (uint256);
    function redeem(uint256 shares_amount, address receiver) external returns (uint256);

    // Purchase functions
    function purchase(uint256[] calldata token_ids) external returns (uint256);

    // View functions
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function sharesOf(address user) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function get_available_inventory() external view returns (uint256);
    function is_token_in_inventory(uint256 token_id) external view returns (bool);
    function quote_purchase(uint256 count) external view returns (uint256);
    function check_liquidity() external view returns (uint256, uint256, uint256);
}
