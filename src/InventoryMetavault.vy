# pragma version ^0.4.0

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from ethereum.ercs import IERC4626
from . import RemyVaultV2 as IRemyVault

# Commented out until needed
# from interfaces.ManagedToken import IManagedToken
from snekmate.extensions import erc4626
from snekmate.utils import math

# Use modules
initializes: erc4626

# Export all ERC4626 functions (overriding totalAssets)
exports: (
    erc4626.asset,
    erc4626.deposit,
    erc4626.withdraw,
    erc4626.mint,
    erc4626.redeem,
    erc4626.maxDeposit,
    erc4626.maxMint,
    erc4626.maxWithdraw,
    erc4626.maxRedeem,
    erc4626.previewDeposit,
    erc4626.previewMint,
    erc4626.previewWithdraw,
    erc4626.previewRedeem,
    erc4626.convertToShares,
    erc4626.convertToAssets,
    erc4626.decimals,
    erc4626.name,
    erc4626.symbol,
    
    # ERC20 functions
    erc4626.totalSupply,
    erc4626.balanceOf,
    erc4626.transfer,
    erc4626.allowance,
    erc4626.approve,
    erc4626.transferFrom
)

################################################################################
# INTERFACE DEFINITIONS
################################################################################

interface IERC721Receiver:
    def onERC721Received(operator: address, from_address: address, token_id: uint256, data: Bytes[1024]) -> bytes4: nonpayable

################################################################################
# STATE VARIABLES
################################################################################

# Core Remy Vault reference
remy_vault: public(IRemyVault)

# NFT collection address - immutable from initialization
nft_collection: public(address)

# Inventory count for the NFT collection
inventory_count: public(uint256)

# Track specific token IDs owned in the inventory
# token_id => is_owned
token_inventory: HashMap[uint256, bool]

# Fee percentage (10% markup = 110% of base price)
MARKUP_BPS: public(uint256)
BPS_DENOMINATOR: constant(uint256) = 1000
MAX_MARKUP_BPS: constant(uint256) = 2000  # 200% maximum markup cap

# Dynamic pricing enabled flag (default: disabled)
dynamic_pricing_enabled: public(bool)

# Max inventory for scaling (above this is considered "full inventory")
MAX_INVENTORY_SCALE: public(uint256)

# Minimum markup percentage (base fee even at max inventory)
MIN_MARKUP_BPS: public(uint256)

# Unit value for calculations
UNIT: constant(uint256) = 1000 * 10**18

# Emergency pause controls
paused: public(bool)

# Total vault tokens from fees accumulated
accumulated_fees: public(uint256)

# Structure for tracking fee events
struct FeeEvent:
    timestamp: uint256
    amount: uint256

# History of fee events
fee_events: public(DynArray[FeeEvent, 100])

# Liquidity threshold - maintain at least this percentage of vault tokens relative to inventory value
# Default: 30% (300 BPS)
LIQUIDITY_THRESHOLD_BPS: public(uint256)

################################################################################
# EVENTS
################################################################################

event InventoryDeposit:
    user: indexed(address)
    token_ids: DynArray[uint256, 100]
    shares_minted: uint256

event InventoryWithdraw:
    user: indexed(address)
    token_ids: DynArray[uint256, 100]
    shares_burned: uint256
    fee_tokens_claimed: uint256  # Fee tokens claimed during withdrawal

event InventoryPurchase:
    buyer: indexed(address) 
    token_ids: DynArray[uint256, 100]
    vault_tokens_paid: uint256

# For inventory tracking
event TokenRegistered:
    token_id: indexed(uint256)

# For fee distribution
event FeesDistributed:
    recipient: indexed(address)
    amount: uint256
    
# For liquidity management
event LiquidityAlert:
    current_liquidity_bps: uint256
    needed_tokens: uint256
    available_tokens: uint256

################################################################################
# ADMIN FUNCTIONS
################################################################################

@external
def deposit_vault_tokens(amount: uint256):
    """
    @dev Deposit core vault tokens to the metavault (liquidity injection)
    @param amount Amount of vault tokens to deposit
    @notice This function allows users to provide vault tokens for future withdrawals
    """
    assert not self.paused, "Contract is paused"
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    assert extcall asset.transferFrom(msg.sender, self, amount)
    
    # Check if more liquidity is needed after deposit
    liquidity_check: (uint256, uint256, uint256) = self._check_liquidity()
    current_liquidity_bps: uint256 = liquidity_check[0]
    needed_tokens: uint256 = liquidity_check[1]
    available_tokens: uint256 = liquidity_check[2]
    
    # If still below threshold, emit an alert
    if current_liquidity_bps < self.LIQUIDITY_THRESHOLD_BPS and needed_tokens > available_tokens:
        log LiquidityAlert(current_liquidity_bps, needed_tokens, available_tokens)
    

################################################################################
# ERC4626 OVERRIDE FUNCTIONS
################################################################################

@internal
@view
def _get_total_assets() -> uint256:
    """
    @dev Returns the total amount of the underlying assets held by the vault
    @return The total assets amount
    """
    # Base assets from inventory (NFTs converted to token value)
    inventory_value: uint256 = self.inventory_count * UNIT
    
    # Add accumulated fees
    total_value: uint256 = inventory_value + self.accumulated_fees
    
    # Add any direct token holdings (excluding accumulated fees to avoid double counting)
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    vault_token_balance: uint256 = staticcall asset.balanceOf(self)
    
    if vault_token_balance > self.accumulated_fees:
        direct_holdings: uint256 = vault_token_balance - self.accumulated_fees
        total_value += direct_holdings
        
    return total_value

@view
@external
def totalAssets() -> uint256:
    """
    @dev Returns the total amount of the underlying assets held by the vault
    @return The total assets amount
    """
    return self._get_total_assets()

@view
@internal
def _convertToShares(assets: uint256, rounding_up: bool) -> uint256:
    """
    @dev Override the standard conversion to account for our fee model
    @param assets Assets to convert to shares
    @param rounding_up Whether to round up or down
    @return Shares amount
    """
    # Get total supply of shares
    supply: uint256 = self._total_supply()
    
    # If there are no shares yet, use 1:1 conversion
    if supply == 0:
        return assets
    
    # Get the total value of the vault including accumulated fees
    total_assets: uint256 = self._get_total_assets()
    
    # If there are no assets, use 1:1 conversion
    if total_assets == 0:
        return assets
    
    # Convert assets to shares based on the current ratio
    # This ensures new depositors get fewer shares when the vault has accumulated fees
    return math._mul_div(assets, supply, total_assets, rounding_up)

@view
@internal
def _convertToAssets(shares: uint256, rounding_up: bool) -> uint256:
    """
    @dev Override the standard conversion to account for our fee model
    @param shares Shares to convert to assets
    @param rounding_up Whether to round up or down
    @return Assets amount
    """
    # Get total supply of shares
    supply: uint256 = self._total_supply()
    
    # If there are no shares, use 1:1 conversion
    if supply == 0:
        return shares
    
    # Get the total value of the vault including accumulated fees
    total_assets: uint256 = self._get_total_assets()
    
    # If there are no assets, use 1:1 conversion
    if total_assets == 0:
        return shares
    
    # Convert shares to assets based on the current ratio
    return math._mul_div(shares, total_assets, supply, rounding_up)

################################################################################
# CORE FUNCTIONS - DEPOSIT/WITHDRAW
################################################################################

@nonreentrant
@external
def deposit_nfts(token_ids: DynArray[uint256, 100], receiver: address = msg.sender) -> uint256:
    """
    @dev Deposit NFTs into the metavault inventory and receive shares
    @param token_ids Array of NFT token IDs to deposit
    @param receiver Address that will receive the shares
    @return Amount of share tokens minted
    """
    assert not self.paused, "Contract is paused"
    assert len(token_ids) > 0, "Empty token array"
    
    # Transfer NFTs to this contract
    nft: IERC721 = IERC721(self.nft_collection)
    for token_id: uint256 in token_ids:
        # Transfer the token
        extcall nft.transferFrom(msg.sender, self, token_id)
        
        # Track this specific token ID
        assert not self.token_inventory[token_id], "Token already in inventory"
        self.token_inventory[token_id] = True
    
    # Update inventory count
    self.inventory_count += len(token_ids)
    
    # Convert NFTs to equivalent asset amount (1 NFT = UNIT tokens)
    asset_amount: uint256 = len(token_ids) * UNIT
    
    # Calculate shares amount using our conversion function
    shares_amount: uint256 = self._convertToShares(asset_amount, False)
    
    # Mint shares directly with ERC4626 mint function
    erc4626._deposit(self, receiver, 0, shares_amount)
    
    log InventoryDeposit(msg.sender, token_ids, shares_amount)
    return shares_amount

@nonreentrant
@external
def withdraw_nfts(token_ids: DynArray[uint256, 100], withdraw_underlying_tokens: bool = True, receiver: address = msg.sender) -> (uint256, uint256):
    """
    @dev Withdraw NFTs by burning shares
    @param token_ids Array of NFT token IDs to withdraw
    @param withdraw_underlying_tokens If true, also withdraw the user's share of accumulated fee tokens
    @param receiver Address that will receive the NFTs
    @return tuple of (Amount of share tokens burned, Amount of underlying vault tokens distributed)
    """
    assert not self.paused, "Contract is paused"
    assert len(token_ids) > 0, "Empty token array"
    
    # Convert NFTs to equivalent asset amount
    asset_amount: uint256 = len(token_ids) * UNIT
    
    # Calculate shares required using our conversion function - round up for withdraw
    shares_amount: uint256 = self._convertToShares(asset_amount, True)
    
    # Track which tokens are served from inventory vs. core vault
    inventory_token_ids: DynArray[uint256, 100] = []
    core_vault_token_ids: DynArray[uint256, 100] = []
    
    # Separate token IDs for processing
    for token_id: uint256 in token_ids:
        if self.token_inventory[token_id]:
            inventory_token_ids.append(token_id)
        else:
            # For core vault tokens, verify the core vault owns them
            nft: IERC721 = IERC721(self.nft_collection)
            core_token_owner: address = staticcall nft.ownerOf(token_id)
            assert core_token_owner == self.remy_vault.address, "Token not owned by core vault"
            core_vault_token_ids.append(token_id)
    
    # Calculate fee share proportional to shares being burned
    fee_tokens_to_claim: uint256 = 0
    
    # If there are accumulated fees and user wants to withdraw them
    if withdraw_underlying_tokens and self.accumulated_fees > 0:
        # Calculate proportional share of accumulated fees based on share of total supply
        total_supply: uint256 = self._total_supply()
        if total_supply > 0:
            fee_tokens_to_claim = shares_amount * self.accumulated_fees // total_supply
            
            # Cap to actual available amount
            if fee_tokens_to_claim > self.accumulated_fees:
                fee_tokens_to_claim = self.accumulated_fees
    
    # Burn shares using the ERC4626 redeem function
    erc4626._withdraw(msg.sender, self, msg.sender, 0, shares_amount)
            
    # Update accumulated fees if claiming
    if fee_tokens_to_claim > 0:
        self.accumulated_fees -= fee_tokens_to_claim
    
    # Process tokens from our inventory
    nft: IERC721 = IERC721(self.nft_collection)
    for token_id: uint256 in inventory_token_ids:
        extcall nft.safeTransferFrom(self, receiver, token_id, b"")
        
        # Remove token ID from tracking
        self.token_inventory[token_id] = False
    
    # Update inventory count
    self.inventory_count -= len(inventory_token_ids)
    
    # Process tokens from core vault - withdraw directly to user
    vault_tokens_needed: uint256 = 0
    if len(core_vault_token_ids) > 0:
        # We need to have enough vault tokens to withdraw from the core vault
        vault_tokens_needed = len(core_vault_token_ids) * UNIT
        
        # Check if we have enough vault tokens in our balance
        asset_address: address = erc4626.asset
        asset: IERC20 = IERC20(asset_address)
        vault_token_balance: uint256 = staticcall asset.balanceOf(self)
        
        # If we don't have enough vault tokens, fail the transaction
        assert vault_token_balance >= vault_tokens_needed + fee_tokens_to_claim, "Insufficient vault tokens"
        
        # Now withdraw from the core vault directly to the user
        # First approve the core vault to take our vault tokens
        remy_vault_address: address = self.remy_vault.address
        assert extcall asset.approve(remy_vault_address, vault_tokens_needed)
        
        # Then withdraw the NFTs directly to the user
        extcall self.remy_vault.batchWithdraw(core_vault_token_ids, receiver)
        
        # After withdrawal, check if our liquidity is getting low
        liquidity_check: (uint256, uint256, uint256) = self._check_liquidity()
        current_liquidity_bps: uint256 = liquidity_check[0]
        needed_tokens: uint256 = liquidity_check[1]
        available_tokens: uint256 = liquidity_check[2]
        
        # If below threshold, emit an alert
        if current_liquidity_bps < self.LIQUIDITY_THRESHOLD_BPS and needed_tokens > available_tokens:
            log LiquidityAlert(current_liquidity_bps, needed_tokens, available_tokens)
    
    # Transfer any fee tokens to the user
    if fee_tokens_to_claim > 0:
        asset_address: address = erc4626.asset
        asset: IERC20 = IERC20(asset_address)
        assert extcall asset.transfer(receiver, fee_tokens_to_claim)
        log FeesDistributed(receiver, fee_tokens_to_claim)
    
    log InventoryWithdraw(msg.sender, token_ids, shares_amount, fee_tokens_to_claim)
    return (shares_amount, fee_tokens_to_claim)

@nonreentrant
@external
def redeem_for_tokens(shares_amount: uint256, receiver: address = msg.sender) -> uint256:
    """
    @dev Redeem shares for the underlying tokens
    @param shares_amount Amount of shares to redeem
    @param receiver Address that will receive the tokens
    @return Amount of tokens received
    """
    assert not self.paused, "Contract is paused"
    assert shares_amount > 0, "Zero shares amount"
    
    # Calculate tokens amount using our conversion function (round down for safety)
    tokens_amount: uint256 = self._convertToAssets(shares_amount, False)
    
    # Ensure we have enough tokens (either from accumulated fees or direct holdings)
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    vault_token_balance: uint256 = staticcall asset.balanceOf(self)
    assert vault_token_balance >= tokens_amount, "Insufficient liquidity"
    
    # Burn the shares using standard erc4626 redeem
    erc4626._withdraw(msg.sender, self, msg.sender, 0, shares_amount)
    
    # Transfer the tokens
    assert extcall asset.transfer(receiver, tokens_amount)
    
    # Update accumulated fees if necessary
    if tokens_amount <= self.accumulated_fees:
        self.accumulated_fees -= tokens_amount
    else:
        # Part of tokens came from accumulated fees, part from direct holdings
        self.accumulated_fees = 0
    
    return tokens_amount

################################################################################
# PURCHASE FUNCTION
################################################################################

@nonreentrant
@external
def purchase_nfts(token_ids: DynArray[uint256, 100]) -> uint256:
    """
    @dev Purchase NFTs from the metavault inventory using core vault ERC20 tokens
    @param token_ids Array of NFT token IDs to purchase
    @return Amount of vault tokens paid
    """
    assert not self.paused, "Contract is paused"
    assert len(token_ids) > 0, "Empty token array"
    assert self.inventory_count >= len(token_ids), "Not enough inventory"
    
    # Verify all tokens are owned by the metavault
    nft: IERC721 = IERC721(self.nft_collection)
    for token_id: uint256 in token_ids:
        # Verify token is in our inventory
        assert self.token_inventory[token_id], "Token not in inventory"
    
    # Calculate price with markup
    base_price: uint256 = UNIT * len(token_ids)
    vault_tokens_required: uint256 = base_price * self.MARKUP_BPS // BPS_DENOMINATOR
    
    # Calculate fee amount (markup portion)
    fee_amount: uint256 = vault_tokens_required - base_price
    
    # Transfer vault tokens from buyer to this contract
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    assert extcall asset.transferFrom(msg.sender, self, vault_tokens_required)
    
    # Transfer NFTs to buyer
    for token_id: uint256 in token_ids:
        extcall nft.safeTransferFrom(self, msg.sender, token_id, b"")
        # Remove token ID from tracking
        self.token_inventory[token_id] = False
    
    # Update inventory count
    self.inventory_count -= len(token_ids)
    
    # Add fee to accumulated fees for shareholders
    if fee_amount > 0:
        self.accumulated_fees += fee_amount
        
        # Record fee event for reporting
        self.fee_events.append(FeeEvent({timestamp: block.timestamp, amount: fee_amount}))
        
        # The share price will automatically adjust with the next call to totalAssets()
    
    # Check liquidity after purchase (since inventory has changed)
    liquidity_check: (uint256, uint256, uint256) = self._check_liquidity()
    current_liquidity_bps: uint256 = liquidity_check[0]
    needed_tokens: uint256 = liquidity_check[1]
    available_tokens: uint256 = liquidity_check[2]
    
    # If below threshold, emit an alert
    if current_liquidity_bps < self.LIQUIDITY_THRESHOLD_BPS and needed_tokens > available_tokens:
        log LiquidityAlert(current_liquidity_bps, needed_tokens, available_tokens)
    
    log InventoryPurchase(msg.sender, token_ids, vault_tokens_required)
    return vault_tokens_required

################################################################################
# LIQUIDITY MANAGEMENT
################################################################################

@view
@internal
def _check_liquidity() -> (uint256, uint256, uint256):
    """
    @dev Check if the contract has enough liquidity to handle withdrawals
    @return Tuple of (current_liquidity_bps, needed_tokens, available_tokens)
    """
    # If no inventory, no need for liquidity
    if self.inventory_count == 0:
        return (BPS_DENOMINATOR, 0, 0)
        
    # Calculate total inventory value in vault tokens
    inventory_value: uint256 = self.inventory_count * UNIT
    
    # Calculate needed tokens based on threshold
    needed_tokens: uint256 = inventory_value * self.LIQUIDITY_THRESHOLD_BPS // BPS_DENOMINATOR
    
    # Get available tokens (excluding accumulated fees that belong to shareholders)
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    vault_token_balance: uint256 = staticcall asset.balanceOf(self)
    available_tokens: uint256 = 0
    
    if vault_token_balance > self.accumulated_fees:
        available_tokens = vault_token_balance - self.accumulated_fees
    
    # Calculate current liquidity ratio
    current_liquidity_bps: uint256 = 0
    if inventory_value > 0:
        current_liquidity_bps = available_tokens * BPS_DENOMINATOR // inventory_value
        
    return (current_liquidity_bps, needed_tokens, available_tokens)

@view
@external
def check_liquidity() -> (uint256, uint256, uint256):
    """
    @dev External version of _check_liquidity for monitoring
    @return Tuple of (current_liquidity_bps, needed_tokens, available_tokens)
    """
    return self._check_liquidity()

################################################################################
# QUOTE FUNCTIONS
################################################################################

@view
@external
def quote_purchase(count: uint256) -> uint256:
    """
    @dev Get the price quote for purchasing NFTs with markup
    @param count Number of NFTs to purchase
    @return Amount of vault tokens required
    """
    base_price: uint256 = UNIT * count
    return base_price * self.MARKUP_BPS // BPS_DENOMINATOR

@view
@external
def get_available_inventory() -> uint256:
    """
    @dev Get the current inventory count
    @return Number of NFTs available in inventory
    """
    return self.inventory_count

@view
@external
def is_token_in_inventory(token_id: uint256) -> bool:
    """
    @dev Check if a specific token ID is in inventory
    @param token_id The token ID to check
    @return True if the token is in inventory
    """
    return self.token_inventory[token_id]

@view
@external
def get_pending_fees_per_share() -> uint256:
    """
    @dev Calculate the pending fees per share
    @return The amount of vault tokens per share unit
    """
    total_supply: uint256 = self._total_supply()
    if total_supply == 0:
        return 0
    return self.accumulated_fees * UNIT // total_supply

@view
@external
def calculate_user_fees(shares_amount: uint256) -> uint256:
    """
    @dev Calculate the pending fees for a specific user based on their shares
    @param shares_amount Amount of shares owned by the user
    @return Amount of vault tokens the user would receive for their shares
    """
    total_supply: uint256 = self._total_supply()
    if total_supply == 0 or shares_amount == 0:
        return 0
    return shares_amount * self.accumulated_fees // total_supply

@view
@internal
def _calculate_user_fee_share(user: address) -> uint256:
    """
    @dev Calculate a user's share of accumulated fees (internal)
    @param user Address of the user
    @return Amount of fee tokens the user is entitled to
    """
    user_shares: uint256 = self._balance_of(user)
    total_supply: uint256 = self._total_supply()
    
    if total_supply == 0 or user_shares == 0:
        return 0
        
    return user_shares * self.accumulated_fees // total_supply

@view
@external
def get_user_fee_share(user: address) -> uint256:
    """
    @dev Calculate a user's share of accumulated fees
    @param user Address of the user
    @return Amount of fee tokens the user is entitled to
    """
    return self._calculate_user_fee_share(user)

################################################################################
# FEE CLAIM FUNCTION
################################################################################

@nonreentrant
@external
def claim_fees() -> uint256:
    """
    @dev Claim accumulated fees without withdrawing NFTs
    @return Amount of fee tokens claimed
    """
    assert not self.paused, "Contract is paused"
    
    # Get user's share balance
    user_shares: uint256 = self._balance_of(msg.sender)
    assert user_shares > 0, "No shares owned"
    
    # Calculate proportional fee share
    fee_tokens_to_claim: uint256 = self._calculate_user_fee_share(msg.sender)
    assert fee_tokens_to_claim > 0, "No fees to claim"
    
    # Update accumulated fees
    self.accumulated_fees -= fee_tokens_to_claim
    
    # Transfer fee tokens to user
    asset_address: address = erc4626.asset
    asset: IERC20 = IERC20(asset_address)
    assert extcall asset.transfer(msg.sender, fee_tokens_to_claim)
    log FeesDistributed(msg.sender, fee_tokens_to_claim)
    
    return fee_tokens_to_claim

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(_remy_vault: address, name: String[25], symbol: String[5]):
    """
    @dev Initialize the Inventory Metavault as an ERC4626 compliant vault
    @param _remy_vault Address of the core RemyVault contract
    @param name The name of the vault shares token
    @param symbol The symbol of the vault shares token
    """
    # Validate inputs
    assert _remy_vault != empty(address), "Invalid RemyVault address"

    # Initialize core contract references
    self.remy_vault = IRemyVault(_remy_vault)
    
    # Get the underlying asset (RemyVault's ERC20 token)
    vault_erc20_address: address = staticcall self.remy_vault.erc20()
    
    # Initialize ERC4626 with proper parameters
    # For EIP-712 domain, use the same name as the token for simplicity
    name_eip712: String[50] = name
    version_eip712: String[20] = "1.0"
    decimals_offset: uint8 = 0
    erc4626.__init__(name, symbol, IERC20(vault_erc20_address), decimals_offset, name_eip712, version_eip712)
    
    # Set the NFT collection to be the same as the core vault's NFT collection
    self.nft_collection = staticcall self.remy_vault.erc721()
    
    # Initialize markup percentage (10% markup = 110%)
    self.MARKUP_BPS = 1100
    
    # Initialize remaining state variables
    self.paused = False
    self.inventory_count = 0
    self.accumulated_fees = 0
    self.LIQUIDITY_THRESHOLD_BPS = 300
    self.dynamic_pricing_enabled = False
    self.MAX_INVENTORY_SCALE = 100
    self.MIN_MARKUP_BPS = 1050
