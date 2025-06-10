// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

interface IRemyVaultV1 {
    // Ownership functions
    function owner() external view returns (address);
    function transfer_owner(address new_owner) external;
    
    // Fee management
    function set_fee_exempt(address account, bool exempt) external;
    function set_fees(uint256[2] calldata fees) external;
    function set_rbtoken_fee_receiver(address receiver) external;
    function mint_fee() external view returns (uint256);
    function redeem_fee() external view returns (uint256);
    function rbtoken_fee_receiver() external view returns (address);
    function fee_exempt(address account) external view returns (bool);
    function charge_fee(uint256 amt) external;
    
    // Vault state
    function set_active(bool active) external;
    function active() external view returns (bool);
    
    // Core functionality
    function mint(uint256 tokenId, address recipient) external;
    function mint_batch(uint256[] calldata tokenIds, address recipient, bool force_fee) external returns (uint256);
    function redeem(uint256 tokenId, address recipient) external;
    function redeem_batch(uint256[] calldata tokenIds, address recipient, bool force_fee) external returns (uint256);
    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    
    // Quote functions
    function quote_redeem(uint256 count, bool force_fee) external view returns (uint256);
    function quote_mint(uint256 count, bool force_fee) external view returns (uint256);
    function quote_redeem_fee(address recipient, uint256 num_tokens) external view returns (uint256);
    function quote_mint_fee(address recipient, uint256 num_tokens) external view returns (uint256);
    
    // Token addresses
    function erc20() external view returns (address);
    function erc721() external view returns (address);
    
    // ERC721 receiver
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}