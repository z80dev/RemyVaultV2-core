# pragma version ^0.4.3
"""
@title InventoryMetavault - NFT Staking and Premium Sales Vault
@dev Manages NFT inventory and orchestrates deposits, withdrawals, and NFT sales
"""

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from ethereum.ercs import IERC4626
from interfaces import IManagedVaultToken as IManagedToken

################################################################################
# CONSTANTS
################################################################################

NFT_UNIT_VALUE: constant(uint256) = 1 * 10**18  # Base value of 1 NFT (1 $REMY)
MARKUP_BPS: public(constant(uint256)) = 1000  # 10% markup (100 $REMY premium)
BPS_DENOMINATOR: constant(uint256) = 10000  # Denominator for basis points

################################################################################
# STATE VARIABLES
################################################################################

# Core contract references
remy_vault: public(address)  # RemyVault address
nft_collection: public(address)  # NFT collection address
core_token: public(address)  # Core vault token address
internal_token: public(address)  # mvREMY token address
staking_vault: public(address)  # StakingVault address

# NFT inventory management
inventory: DynArray[uint256, 1000]  # List of NFT IDs in inventory
is_in_inventory: HashMap[uint256, bool]  # Quick lookup for NFT status
inventory_count: public(uint256)  # Count of NFTs in inventory

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

event InventoryPurchase:
    buyer: indexed(address)
    token_ids: DynArray[uint256, 100]
    vault_tokens_paid: uint256

event TokenRegistered:
    token_id: indexed(uint256)

interface RemyVault:
    def erc721() -> address: view
    def erc20() -> address: view

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(
    remy_vault_address: address, 
    internal_token_address: address,
    staking_vault_address: address
):
    """
    @dev Initialize the metavault
    @param remy_vault_address Address of the RemyVault contract
    @param internal_token_address Address of the mvREMY token
    @param staking_vault_address Address of the StakingVault contract
    """
    self.remy_vault = remy_vault_address
    self.nft_collection = staticcall RemyVault(remy_vault_address).erc721()
    self.core_token = staticcall RemyVault(remy_vault_address).erc20()
    self.internal_token = internal_token_address
    self.staking_vault = staking_vault_address

################################################################################
# CORE DEPOSIT FUNCTIONS
################################################################################

@external
@nonreentrant
def deposit(token_ids: DynArray[uint256, 100], receiver: address) -> uint256:
    """
    @dev Deposit NFTs into the metavault and receive stMV shares
    @param token_ids NFT token IDs to deposit
    @param receiver Address to receive the stMV shares
    @return Amount of stMV shares minted
    """
    # Safety check
    assert len(token_ids) > 0, "No NFTs provided"
    
    # Transfer NFTs from user to this contract
    self._take_nfts(token_ids, msg.sender)

    # Mint internal tokens to self (1000 mvREMY value per NFT)
    internal_value: uint256 = len(token_ids) * NFT_UNIT_VALUE
    mv_token: IManagedToken = IManagedToken(self.internal_token)
    extcall mv_token.mint(self, internal_value)
    
    # Approve StakingVault to spend internal tokens
    internal_erc20: IERC20 = IERC20(self.internal_token)
    extcall internal_erc20.approve(self.staking_vault, internal_value)
    
    # Deposit internal tokens into StakingVault on behalf of the receiver
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    shares_amount: uint256 = extcall staking_vault.deposit(internal_value, receiver)

    # Emit event
    log InventoryDeposit(user=receiver, token_ids=token_ids, shares_minted=shares_amount)
    
    return shares_amount

################################################################################
# HELPER FNS
################################################################################

@internal
def _take_nfts(token_ids: DynArray[uint256, 100], owner: address):
    """
    @dev Transfer NFTs from a sender
    @param token_ids NFT token IDs to transfer
    @param from Address to take NFTs from
    """
    nft: IERC721 = IERC721(self.nft_collection)
    for token_id: uint256 in token_ids:
        extcall nft.transferFrom(owner, self, token_id)
        if not self.is_in_inventory[token_id]:
            self.inventory.append(token_id)
            self.is_in_inventory[token_id] = True
            log TokenRegistered(token_id=token_id)

    self.inventory_count += len(token_ids)

@internal
def _send_nfts(token_ids: DynArray[uint256, 100], receiver: address):
    """
    @dev Transfer NFTs to a receiver
    @param token_ids NFT token IDs to transfer
    @param receiver Address to receive the NFTs
    """
    nft: IERC721 = IERC721(self.nft_collection)
    for token_id: uint256 in token_ids:
        self._remove_from_inventory(token_id)
        extcall nft.transferFrom(self, receiver, token_id)

    self.inventory_count -= len(token_ids)

################################################################################
# CORE WITHDRAWAL FUNCTIONS
################################################################################

@external
@nonreentrant
def withdraw(token_ids: DynArray[uint256, 100], receiver: address) -> uint256:
    """
    @dev Withdraw specific NFTs by redeeming shares
    @param token_ids NFT token IDs to withdraw
    @param receiver Address to receive NFTs
    @return Amount of shares burned
    """
    # Safety check
    assert len(token_ids) > 0, "No NFTs provided"
    
    # Calculate internal value of NFTs
    internal_value: uint256 = len(token_ids) * NFT_UNIT_VALUE
    
    # Calculate shares to burn based on internal value
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    shares_to_burn: uint256 = staticcall staking_vault.previewWithdraw(internal_value)
    
    # Verify user has enough shares
    assert shares_to_burn <= staticcall IERC20(self.staking_vault).balanceOf(msg.sender), "Insufficient shares"
    
    # Verify NFTs are in inventory
    for token_id: uint256 in token_ids:
        assert self.is_in_inventory[token_id], "NFT not in inventory"
    
    # Redeem shares from the staking vault
    extcall staking_vault.withdraw(internal_value, self, msg.sender)
    
    # Burn the internal tokens
    mv_token: IManagedToken = IManagedToken(self.internal_token)
    extcall mv_token.burn(self, internal_value)
    
    # Transfer NFTs to receiver
    self._send_nfts(token_ids, receiver)

    # Emit event
    log InventoryWithdraw(user=msg.sender, token_ids=token_ids, shares_burned=shares_to_burn)
    
    return shares_to_burn

@external
@nonreentrant
def redeem(shares_amount: uint256, receiver: address) -> uint256:
    """
    @dev Redeem stMV shares for a combination of NFTs and REMY tokens
    @param shares_amount Amount of shares to redeem
    @param receiver Address to receive assets
    @return Amount of assets redeemed
    """
    # Safety checks
    assert shares_amount > 0, "No shares provided"
    
    # Get the staking vault
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    
    # Check user has enough shares
    assert shares_amount <= staticcall IERC20(self.staking_vault).balanceOf(msg.sender), "Insufficient shares"
    
    # Calculate amount of internal tokens to withdraw
    internal_tokens: uint256 = staticcall staking_vault.previewRedeem(shares_amount)
    
    # Redeem shares from staking vault
    extcall staking_vault.redeem(shares_amount, self, msg.sender)
    
    # Calculate how many whole NFTs the user is entitled to
    nft_count: uint256 = internal_tokens // NFT_UNIT_VALUE
    remy_remainder: uint256 = internal_tokens % NFT_UNIT_VALUE
    
    # Verify we have enough NFTs
    if nft_count > self.inventory_count:
        nft_count = self.inventory_count
        # Additional value converted to REMY
        remy_remainder += (internal_tokens - (nft_count * NFT_UNIT_VALUE))
    
    # Burn the internal tokens
    mv_token: IManagedToken = IManagedToken(self.internal_token)
    extcall mv_token.burn(self, internal_tokens)
    
    # Transfer NFTs if any
    if nft_count > 0:
        nfts_to_transfer: DynArray[uint256, 100] = []
        count: uint256 = 0
        
        # Get NFTs from inventory
        inventory_size: uint256 = len(self.inventory)
        max_iterations: uint256 = 100
        if inventory_size < max_iterations:
            max_iterations = inventory_size
            
        for i: uint256 in range(100):  # Use a constant
            if i >= max_iterations:
                break
            if count >= nft_count:
                break
                
            token_id: uint256 = self.inventory[i]
            nfts_to_transfer.append(token_id)
            count += 1

        # Transfer NFTs to receiver
        self._send_nfts(nfts_to_transfer, receiver)
    
    # Transfer any REMY remainder
    if remy_remainder > 0:
        remy_token: IERC20 = IERC20(self.core_token)
        extcall remy_token.transfer(receiver, remy_remainder)
    
    # Return the total asset value redeemed
    return internal_tokens

################################################################################
# NFT PURCHASE FUNCTIONS
################################################################################

@external
@nonreentrant
def purchase(token_ids: DynArray[uint256, 100]) -> uint256:
    """
    @dev Purchase NFTs from the metavault at premium price
    @param token_ids NFT token IDs to purchase
    @return Total amount of REMY paid
    """
    # Safety check
    assert len(token_ids) > 0, "No NFTs provided"
    
    # Calculate premium price
    base_price: uint256 = len(token_ids) * NFT_UNIT_VALUE
    premium: uint256 = base_price * MARKUP_BPS // BPS_DENOMINATOR
    total_price: uint256 = base_price + premium
    
    # Verify NFTs are in inventory
    for token_id: uint256 in token_ids:
        assert self.is_in_inventory[token_id], "NFT not in inventory"
    
    # Transfer REMY from buyer to this contract
    remy_vault_contract: address = self.remy_vault
    remy_token_address: address = self.core_token
    remy_token: IERC20 = IERC20(remy_token_address)
    extcall remy_token.transferFrom(msg.sender, self, total_price)

    # Transfer NFTs to buyer
    self._send_nfts(token_ids, msg.sender)
    
    # Emit event
    log InventoryPurchase(buyer=msg.sender, token_ids=token_ids, vault_tokens_paid=total_price)

    # mint 100 mvREMY tokens to the erc4626 contract
    mv_token: IManagedToken = IManagedToken(self.internal_token)
    extcall mv_token.mint(self.staking_vault, premium)

    return total_price

################################################################################
# VIEW FUNCTIONS
################################################################################

@view
@external
def totalAssets() -> uint256:
    """
    @dev Calculate total assets managed by the metavault
         This includes the value of NFTs and REMY tokens
    @return Total assets value in REMY tokens
    """
    # Value of NFTs in inventory (represented by internal tokens)
    nft_value: uint256 = self.inventory_count * NFT_UNIT_VALUE
    
    # Value of REMY tokens held by metavault
    remy_vault_contract: address = self.remy_vault
    remy_token_address: address = self.core_token
    remy_token: IERC20 = IERC20(remy_token_address)
    remy_value: uint256 = staticcall remy_token.balanceOf(self)
    
    # Total assets = NFT value + REMY value
    return nft_value + remy_value

@view
@external
def totalShares() -> uint256:
    """
    @dev Get total shares in circulation
    @return Total amount of shares
    """
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    return staticcall IERC20(self.staking_vault).totalSupply()

@view
@external
def sharesOf(user: address) -> uint256:
    """
    @dev Get shares owned by a user
    @param user Address of the user
    @return Amount of shares owned
    """
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    return staticcall IERC20(self.staking_vault).balanceOf(user)

@view
@external
def convertToShares(assets: uint256) -> uint256:
    """
    @dev Convert asset amount to share amount
    @param assets Amount of assets to convert
    @return Equivalent amount of shares
    """
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    return staticcall staking_vault.convertToShares(assets)

@view
@external
def convertToAssets(shares: uint256) -> uint256:
    """
    @dev Convert share amount to asset amount
    @param shares Amount of shares to convert
    @return Equivalent amount of assets
    """
    staking_vault: IERC4626 = IERC4626(self.staking_vault)
    return staticcall staking_vault.convertToAssets(shares)

@view
@external
def get_available_inventory() -> uint256:
    """
    @dev Get count of NFTs available in inventory
    @return Number of NFTs in inventory
    """
    return self.inventory_count

@view
@external
def is_token_in_inventory(token_id: uint256) -> bool:
    """
    @dev Check if a specific NFT is in inventory
    @param token_id ID of the NFT to check
    @return True if the NFT is in inventory
    """
    return self.is_in_inventory[token_id]

@view
@external
def quote_purchase(count: uint256) -> uint256:
    """
    @dev Quote the price to purchase a number of NFTs
    @param count Number of NFTs to purchase
    @return Total price in REMY tokens
    """
    base_price: uint256 = count * NFT_UNIT_VALUE
    premium: uint256 = base_price * MARKUP_BPS // BPS_DENOMINATOR
    return base_price + premium

################################################################################
# UTILITY FUNCTIONS
################################################################################

@internal
def _remove_from_inventory(token_id: uint256):
    """
    @dev Remove an NFT from inventory
    @param token_id ID of the NFT to remove
    """
    # Find and remove from inventory array
    inventory_size: uint256 = len(self.inventory)
    for i: uint256 in range(1000):  # Use a reasonable bound
        if i >= inventory_size:
            break
        if self.inventory[i] == token_id:
            # Move the last element to this position (if not already last)
            if i < len(self.inventory) - 1:
                self.inventory[i] = self.inventory[len(self.inventory) - 1]
            
            # Remove last element
            self.inventory.pop()
            self.is_in_inventory[token_id] = False
            break
