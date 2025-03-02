# pragma version ^0.4.0

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from interfaces import ManagedToken as IManagedToken
from snekmate.auth import ownable

initializes: ownable

################################################################################
# INTERFACE DEFINITIONS
################################################################################

interface IRemyVault:
    def erc20() -> address: view
    def erc721() -> address: view
    def quoteDeposit(count: uint256) -> uint256: pure
    def quoteWithdraw(count: uint256) -> uint256: pure
    def deposit(tokenId: uint256, recipient: address): nonpayable
    def batchDeposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256: nonpayable
    def withdraw(tokenId: uint256, recipient: address): nonpayable
    def batchWithdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256: nonpayable

interface IERC721Receiver:
    def onERC721Received(operator: address, from_address: address, token_id: uint256, data: Bytes[1024]) -> bytes4: nonpayable

################################################################################
# STATE VARIABLES
################################################################################

# We'll use snekmate's ownable functionality directly

# Core Remy Vault reference
remy_vault: public(IRemyVault)

# ERC20 token of the core vault
vault_erc20: public(IERC20)

# Metavault ERC20 token that represents shares of the inventory metavault
shares_token: public(IERC20)

# Inventory of NFT contracts we are tracking
# contract_address => is_supported
supported_nfts: HashMap[address, bool]

# Inventory count per contract
# contract_address => count
nft_inventory: HashMap[address, uint256]

# Track specific token IDs owned per contract
# contract_address => token_id => is_owned
nft_token_ids: HashMap[address, HashMap[uint256, bool]]

# Fee percentage (10% markup = 110% of base price)
MARKUP_BPS: constant(uint256) = 1100 # 110%
BPS_DENOMINATOR: constant(uint256) = 1000

# Unit value for calculations
UNIT: constant(uint256) = 1000 * 10 ** 18

################################################################################
# EVENTS
################################################################################

event NftContractAdded:
    nft_contract: indexed(address)

event NftContractRemoved:
    nft_contract: indexed(address)

event InventoryDeposit:
    user: indexed(address)
    nft_contract: indexed(address)
    token_ids: DynArray[uint256, 100]
    shares_minted: uint256

event InventoryWithdraw:
    user: indexed(address)
    nft_contract: indexed(address)
    token_ids: DynArray[uint256, 100]
    shares_burned: uint256

event InventoryPurchase:
    buyer: indexed(address) 
    nft_contract: indexed(address)
    token_ids: DynArray[uint256, 100]
    vault_tokens_paid: uint256

################################################################################
# EVENTS (CONTINUED)
################################################################################

################################################################################
# ADMIN FUNCTIONS
################################################################################

@external
def add_nft_contract(nft_contract: address):
    """
    @dev Add an NFT contract to the supported inventory
    @param nft_contract Address of the NFT contract to support
    """
    ownable._check_owner()
    self.supported_nfts[nft_contract] = True
    log NftContractAdded(nft_contract)

@external
def remove_nft_contract(nft_contract: address):
    """
    @dev Remove an NFT contract from the supported inventory
    @param nft_contract Address of the NFT contract to remove
    """
    ownable._check_owner()
    assert self.nft_inventory[nft_contract] == 0, "Cannot remove contract with inventory"
    self.supported_nfts[nft_contract] = False
    log NftContractRemoved(nft_contract)

# For inventory tracking
event TokenRegistered:
    nft_contract: indexed(address)
    token_id: indexed(uint256)

@external
def register_token_in_inventory(nft_contract: address, token_id: uint256):
    """
    @dev Manually register a token ID as being in our inventory
    @notice This is useful when tokens are directly transferred to the contract
            without using the deposit function
    @param nft_contract The NFT contract address
    @param token_id The token ID to register
    """
    ownable._check_owner()
    
    # Verify we actually own this token
    nft: IERC721 = IERC721(nft_contract)
    owner: address = staticcall nft.ownerOf(token_id)
    assert owner == self, "Contract doesn't own this token"
    
    # Register the token
    if not self.nft_token_ids[nft_contract][token_id]:
        self.nft_token_ids[nft_contract][token_id] = True
        self.nft_inventory[nft_contract] += 1
        log TokenRegistered(nft_contract, token_id)

################################################################################
# CORE FUNCTIONS - DEPOSIT/WITHDRAW
################################################################################

@nonreentrant
@external
def deposit_nfts(nft_contract: address, token_ids: DynArray[uint256, 100]) -> uint256:
    """
    @dev Deposit NFTs into the metavault inventory and receive shares
    @param nft_contract The address of the NFT contract
    @param token_ids Array of NFT token IDs to deposit
    @return Amount of share tokens minted
    """
    assert self.supported_nfts[nft_contract], "NFT contract not supported"
    
    # Transfer NFTs to this contract
    nft: IERC721 = IERC721(nft_contract)
    for token_id: uint256 in token_ids:
        extcall nft.transferFrom(msg.sender, self, token_id)
        # Track this specific token ID
        self.nft_token_ids[nft_contract][token_id] = True
    
    # Update inventory count
    self.nft_inventory[nft_contract] += len(token_ids)
    
    # Mint shares tokens (1 share per NFT)
    shares_amount: uint256 = len(token_ids) * UNIT
    extcall IManagedToken(self.shares_token.address).mint(msg.sender, shares_amount)
    
    log InventoryDeposit(msg.sender, nft_contract, token_ids, shares_amount)
    return shares_amount

@nonreentrant
@external
def withdraw_nfts(nft_contract: address, token_ids: DynArray[uint256, 100]) -> uint256:
    """
    @dev Withdraw NFTs by burning shares - NFTs can come from either metavault inventory or core vault
    @param nft_contract The address of the NFT contract
    @param token_ids Array of NFT token IDs to withdraw
    @return Amount of share tokens burned
    """
    assert self.supported_nfts[nft_contract], "NFT contract not supported"
    
    # Calculate shares to burn
    shares_amount: uint256 = len(token_ids) * UNIT
    
    # Burn shares tokens
    extcall self.shares_token.transferFrom(msg.sender, self, shares_amount)
    extcall IManagedToken(self.shares_token.address).burn(shares_amount)
    
    # Get core vault's ERC721 address
    core_vault_nft_address: address = staticcall self.remy_vault.erc721()
    is_core_nft: bool = (nft_contract == core_vault_nft_address)
    
    # Track which tokens are served from inventory vs. core vault
    inventory_token_ids: DynArray[uint256, 100] = []
    core_vault_token_ids: DynArray[uint256, 100] = []
    
    # Separate token IDs for processing
    for token_id: uint256 in token_ids:
        # Try to get the token from our inventory first if we have it
        if nft_contract == core_vault_nft_address and self._is_token_in_metavault_inventory(token_id):
            inventory_token_ids.append(token_id)
        else:
            # Otherwise get it from the core vault
            core_vault_token_ids.append(token_id)
    
    # Process tokens from our inventory
    nft: IERC721 = IERC721(nft_contract)
    for token_id: uint256 in inventory_token_ids:
        extcall nft.safeTransferFrom(self, msg.sender, token_id)
        # Remove token ID from tracking
        self.nft_token_ids[nft_contract][token_id] = False
        # Update inventory count
        self.nft_inventory[nft_contract] -= 1
    
    # Process tokens from core vault - withdraw directly to user
    if len(core_vault_token_ids) > 0:
        if is_core_nft:
            # We need to have enough vault tokens to withdraw from the core vault
            vault_tokens_needed: uint256 = len(core_vault_token_ids) * UNIT
            
            # First check if we have enough vault tokens in our balance
            vault_token_balance: uint256 = staticcall self.vault_erc20.balanceOf(self)
            
            # If we don't have enough vault tokens, acquire them by:
            # 1. Either using the core vault's ERC20s from our balance
            # 2. Or by depositing NFTs into the core vault to get ERC20s
            if vault_token_balance < vault_tokens_needed:
                # First look for NFTs that we can deposit into the core vault
                # We should have at least some core NFTs in our inventory
                available_deposit_nfts: DynArray[uint256, 100] = self._find_nfts_to_deposit(len(core_vault_token_ids))
                
                # If we found enough NFTs to deposit, use them to get vault tokens
                if len(available_deposit_nfts) > 0:
                    # Approve the core vault to take our NFTs
                    core_nft: IERC721 = IERC721(core_vault_nft_address)
                    remy_vault_address: address = self.remy_vault.address
                    for deposit_token_id: uint256 in available_deposit_nfts:
                        extcall core_nft.approve(remy_vault_address, deposit_token_id)
                    
                    # Deposit the NFTs to get vault tokens
                    extcall self.remy_vault.batchDeposit(available_deposit_nfts, self)
                    
                    # Update our inventory count and tracking
                    for deposit_token_id: uint256 in available_deposit_nfts:
                        self.nft_inventory[core_vault_nft_address] -= 1
                        # Remove token from tracking
                        self.nft_token_ids[core_vault_nft_address][deposit_token_id] = False
                else:
                    # If we still don't have enough tokens and no NFTs to deposit, fail
                    assert False, "Insufficient vault tokens to process withdrawal"
            
            # Now withdraw from the core vault directly to the user
            # First approve the core vault to take our vault tokens
            remy_vault_address: address = self.remy_vault.address
            extcall self.vault_erc20.approve(remy_vault_address, vault_tokens_needed)
            
            # Then withdraw the NFTs directly to the user
            extcall self.remy_vault.batchWithdraw(core_vault_token_ids, msg.sender)
        else:
            # For other supported NFTs, we'd need another mechanism
            # This section would handle other NFT withdrawals if applicable
            assert False, "Withdrawal from core vault for non-core NFTs not implemented"
    
    log InventoryWithdraw(msg.sender, nft_contract, token_ids, shares_amount)
    return shares_amount

@view
@internal
def _is_token_in_metavault_inventory(token_id: uint256) -> bool:
    """
    @dev Check if a specific token ID is owned by this metavault
    @param token_id The token ID to check
    @return True if the token is in this metavault's inventory
    """
    core_vault_nft_address: address = staticcall self.remy_vault.erc721()
    return self.nft_token_ids[core_vault_nft_address][token_id]

@internal
def _find_nfts_to_deposit(count_needed: uint256) -> DynArray[uint256, 100]:
    """
    @dev Find NFTs in our inventory that we can deposit to the core vault to get ERC20 tokens
    @param count_needed Number of NFTs needed
    @return Array of NFT token IDs that can be deposited
    """
    result: DynArray[uint256, 100] = []
    
    # If we don't need any NFTs, return empty array
    if count_needed == 0:
        return result
    
    # Get the core vault's NFT address
    core_vault_nft_address: address = staticcall self.remy_vault.erc721()
    
    # Make sure we have NFTs in our inventory of the core vault's NFT type
    if self.nft_inventory[core_vault_nft_address] == 0:
        return result
    
    # Note: In a real implementation, we would need a way to iterate through 
    # token IDs we own. Since Vyper doesn't support iteration over mappings,
    # we would need to maintain a separate list of token IDs or use an enumerable
    # ERC721 implementation.
    
    # For now, we'll implement a simple version where the admin can register
    # available token IDs for withdrawal
    
    # This is a placeholder for the actual implementation which would depend on
    # how the contract tracks owned tokens
    
    return result

################################################################################
# PURCHASE FUNCTION
################################################################################

@nonreentrant
@external
def purchase_nfts(nft_contract: address, token_ids: DynArray[uint256, 100]) -> uint256:
    """
    @dev Purchase NFTs from the metavault inventory using core vault ERC20 tokens
    @param nft_contract The address of the NFT contract
    @param token_ids Array of NFT token IDs to purchase
    @return Amount of vault tokens paid
    """
    assert self.supported_nfts[nft_contract], "NFT contract not supported"
    assert self.nft_inventory[nft_contract] >= len(token_ids), "Not enough inventory"
    
    # Calculate price with 10% markup
    base_price: uint256 = UNIT * len(token_ids)
    vault_tokens_required: uint256 = base_price * MARKUP_BPS // BPS_DENOMINATOR
    
    # Transfer vault tokens from buyer to this contract
    extcall self.vault_erc20.transferFrom(msg.sender, self, vault_tokens_required)
    
    # Transfer NFTs to buyer
    nft: IERC721 = IERC721(nft_contract)
    for token_id: uint256 in token_ids:
        extcall nft.safeTransferFrom(self, msg.sender, token_id)
        # Remove token ID from tracking
        self.nft_token_ids[nft_contract][token_id] = False
    
    # Update inventory count
    self.nft_inventory[nft_contract] -= len(token_ids)
    
    log InventoryPurchase(msg.sender, nft_contract, token_ids, vault_tokens_required)
    return vault_tokens_required

################################################################################
# QUOTE FUNCTIONS
################################################################################

@view
@external
def quote_purchase(nft_contract: address, count: uint256) -> uint256:
    """
    @dev Get the price quote for purchasing NFTs with markup
    @param nft_contract The address of the NFT contract (unused but kept for consistency)
    @param count Number of NFTs to purchase
    @return Amount of vault tokens required
    """
    base_price: uint256 = UNIT * count
    return base_price * MARKUP_BPS // BPS_DENOMINATOR

@view
@external
def get_available_inventory(nft_contract: address) -> uint256:
    """
    @dev Get the current inventory count for a particular NFT contract
    @param nft_contract The address of the NFT contract
    @return Number of NFTs available in inventory
    """
    return self.nft_inventory[nft_contract]

@view
@external
def is_supported_contract(nft_contract: address) -> bool:
    """
    @dev Check if an NFT contract is supported by this metavault
    @param nft_contract The address of the NFT contract
    @return True if the contract is supported
    """
    return self.supported_nfts[nft_contract]

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(_remy_vault: address, _shares_token: address):
    """
    @dev Initialize the Inventory Metavault
    @param _remy_vault Address of the core RemyVault contract
    @param _shares_token Address of the ERC20 token for metavault shares
    """
    # Initialize core contract references
    self.remy_vault = IRemyVault(_remy_vault)
    vault_erc20_address: address = staticcall self.remy_vault.erc20()
    self.vault_erc20 = IERC20(vault_erc20_address)
    self.shares_token = IERC20(_shares_token)
    
    # Initialize ownable
    ownable.__init__()

################################################################################
# ERC721 RECEIVER IMPLEMENTATION
################################################################################

@external
def onERC721Received(operator: address, from_address: address, token_id: uint256, data: Bytes[1024]) -> bytes4:
    """
    @dev Implement ERC721Receiver interface to allow direct transfers
    @return bytes4 The function selector
    """
    return 0x150b7a02 # bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
