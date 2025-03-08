// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IERC4626.sol";

interface IInventoryMetavault is IERC4626 {
    // ERC4626 Functions are already included from the IERC4626 interface

    // Events
    event InventoryDeposit(address indexed user, uint256[] token_ids, uint256 shares_minted);
    event InventoryWithdraw(address indexed user, uint256[] token_ids, uint256 shares_burned, uint256 fee_tokens_claimed);
    event InventoryPurchase(address indexed buyer, uint256[] token_ids, uint256 vault_tokens_paid);
    event TokenRegistered(uint256 indexed token_id);
    event FeesDistributed(address indexed recipient, uint256 amount);
    event LiquidityAlert(uint256 current_liquidity_bps, uint256 needed_tokens, uint256 available_tokens);

    // View functions
    function remy_vault() external view returns (address);
    function nft_collection() external view returns (address);
    function inventory_count() external view returns (uint256);
    function MARKUP_BPS() external view returns (uint256);
    function LIQUIDITY_THRESHOLD_BPS() external view returns (uint256);
    function paused() external view returns (bool);
    function accumulated_fees() external view returns (uint256);
    function quote_purchase(uint256 count) external view returns (uint256);
    function get_available_inventory() external view returns (uint256);
    function is_token_in_inventory(uint256 token_id) external view returns (bool);
    function get_pending_fees_per_share() external view returns (uint256);
    function calculate_user_fees(uint256 shares_amount) external view returns (uint256);
    function get_user_fee_share(address user) external view returns (uint256);
    function check_liquidity() external view returns (uint256, uint256, uint256);

    // Non-admin functions
    function deposit_vault_tokens(uint256 amount) external;
    
    // NFT handling functions
    function deposit_nfts(uint256[] calldata token_ids, address receiver) external returns (uint256);
    function withdraw_nfts(uint256[] calldata token_ids, bool withdraw_underlying_tokens, address receiver) external returns (uint256, uint256);
    function purchase_nfts(uint256[] calldata token_ids) external returns (uint256);
    function redeem_for_tokens(uint256 shares_amount, address receiver) external returns (uint256);
    function claim_fees() external returns (uint256);
    function onERC721Received(address operator, address from_address, uint256 token_id, bytes calldata data) external returns (bytes4);
}