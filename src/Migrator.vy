# pragma version ^0.4.3

from ethereum.ercs import IERC20

# ERC721Enumerable interface
interface IERC721Enumerable:
    def totalSupply() -> uint256: view
    def tokenOfOwnerByIndex(owner: address, index: uint256) -> uint256: view
    def tokenByIndex(index: uint256) -> uint256: view
    def balanceOf(owner: address) -> uint256: view
    def ownerOf(tokenId: uint256) -> address: view
    def safeTransferFrom(from_addr: address, to: address, tokenId: uint256): nonpayable
    def transferFrom(from_addr: address, to: address, tokenId: uint256): nonpayable
    def approve(to: address, tokenId: uint256): nonpayable
    def setApprovalForAll(operator: address, approved: bool): nonpayable
    def getApproved(tokenId: uint256) -> address: view
    def isApprovedForAll(owner: address, operator: address) -> bool: view

# RescueRouterV2 interface - includes new token swap function
interface IRescueRouterV2:
    def swap_tokens_for_nfts(tokenIds: DynArray[uint256, 100], recipient: address): nonpayable
    def quote_tokens_for_nfts(tokenIds: DynArray[uint256, 100]) -> uint256: view

# RemyVault v2 interface - for depositing NFTs
interface IRemyVaultV2:
    def deposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256: nonpayable

# RemyVault v1 interface - for withdrawing NFTs
interface IRemyVaultV1:
    def withdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256: nonpayable

remyv1: public(IERC20)
remyv2: public(IERC20)

vaultv1: public(address)
vaultv2: public(address)
rescue_router: public(address)
nft: public(address)

# Constants
TOKEN_UNIT: constant(uint256) = 10**18
LEGACY_TOKENS_PER_NFT: constant(uint256) = 1000 * TOKEN_UNIT
NEW_TOKENS_PER_NFT: constant(uint256) = 1000 * TOKEN_UNIT

event Migrated:
    user: indexed(address)
    remy_v1_amount: uint256
    remy_v2_amount: uint256
    nfts_redeemed: uint256
    leftover_tokens_swapped: uint256

@deploy
def __init__(remyv1: address, remyv2: address, vaultv1: address, vaultv2: address, _rescue_router: address, _nft: address):
    """
    @dev Initializes the Migrator contract
    @param remyv1 The address of the old REMY token
    @param remyv2 The address of the new REMY token
    @param vaultv1 The address of the old vault
    @param vaultv2 The address of the new vault
    @param _rescue_router The address of the RescueRouterV2 contract
    @param _nft The address of the NFT contract
    """
    self.remyv1 = IERC20(remyv1)
    self.remyv2 = IERC20(remyv2)
    self.vaultv1 = vaultv1
    self.vaultv2 = vaultv2
    self.rescue_router = _rescue_router
    self.nft = _nft

@view
@external
def quote_migration_cost(num_nfts: uint256) -> uint256:
    """
    @dev Get the cost of migrating a specific number of NFTs
    @param num_nfts The number of NFTs to migrate
    @return The amount of REMY v1 tokens required
    """
    if num_nfts == 0 or num_nfts > 100:
        return 0
    
    # Create array of token IDs (we'll use dummy IDs for quote)
    token_ids: DynArray[uint256, 100] = []
    for i: uint256 in range(num_nfts, bound=100):
        token_ids.append(i)
    
    # V2 router quotes based on the redeem cost
    return staticcall IRescueRouterV2(self.rescue_router).quote_tokens_for_nfts(token_ids)

@view
@external
def get_token_balances() -> (uint256, uint256):
    """
    @dev Get the current v1 and v2 token balances of the migrator
    @return Tuple of (v1_balance, v2_balance)
    """
    v1_balance: uint256 = staticcall self.remyv1.balanceOf(self)
    v2_balance: uint256 = staticcall self.remyv2.balanceOf(self)
    return (v1_balance, v2_balance)

@external
def migrate():
    """
    @dev Migrates the old REMY tokens to the new REMY tokens
    """
    # Get the balance of the old REMY token
    balance: uint256 = staticcall self.remyv1.balanceOf(msg.sender)

    # Check if the user has any old REMY tokens
    assert balance > 0, "No old REMY tokens to migrate"

    # Transfer the old REMY tokens to the migrator
    extcall self.remyv1.transferFrom(msg.sender, self, balance)

    # Calculate how many full NFTs can be redeemed
    max_nfts: uint256 = balance // LEGACY_TOKENS_PER_NFT
    
    # Calculate leftover tokens that don't make a full NFT
    leftover_tokens: uint256 = balance % LEGACY_TOKENS_PER_NFT
    
    remy_v2_received: uint256 = 0

    # Only process NFT redemption if there are full NFTs to redeem
    if max_nfts > 0:
        # Get the NFT contract as IERC721Enumerable
        nft_contract: IERC721Enumerable = IERC721Enumerable(self.nft)
        
        # Get the number of NFTs owned by the v1 vault
        vault_nft_balance: uint256 = staticcall nft_contract.balanceOf(self.vaultv1)
        
        assert vault_nft_balance >= max_nfts, "Insufficient NFTs in v1 vault"

        token_ids: DynArray[uint256, 100] = []
        
        for i: uint256 in range(max_nfts, bound=100):
            # Get the token ID of the NFT at index i
            token_id: uint256 = staticcall nft_contract.tokenOfOwnerByIndex(self.vaultv1, i)
            token_ids.append(token_id)

        # Calculate tokens needed for NFT redemption
        tokens_for_nfts: uint256 = max_nfts * LEGACY_TOKENS_PER_NFT
        
        # Approve rescue router to use our REMY v1 tokens (only for NFT redemption)
        extcall self.remyv1.approve(self.rescue_router, tokens_for_nfts)

        # Use the V2 router's direct token swap function
        # This function will transfer tokens from us and redeem NFTs directly
        extcall IRescueRouterV2(self.rescue_router).swap_tokens_for_nfts(token_ids, self)

        # Approve v2 vault to transfer our NFTs
        extcall nft_contract.setApprovalForAll(self.vaultv2, True)
        
        # Deposit NFTs into v2 vault to get REMY v2
        # The v2 vault will mint REMY v2 tokens directly to the user
        remy_v2_received = extcall IRemyVaultV2(self.vaultv2).deposit(token_ids, msg.sender)
    
    # Handle leftover tokens by swapping them 1:1
    if leftover_tokens > 0:
        # Convert leftover v1 tokens into v2 units based on the new ratio
        v2_from_leftover: uint256 = leftover_tokens * NEW_TOKENS_PER_NFT // LEGACY_TOKENS_PER_NFT
        extcall self.remyv2.transfer(msg.sender, v2_from_leftover)
        remy_v2_received += v2_from_leftover
    
    # Verify invariant: total v2 value held by migrator equals prefunded amount
    v1_balance: uint256 = staticcall self.remyv1.balanceOf(self)
    v2_balance: uint256 = staticcall self.remyv2.balanceOf(self)
    migrated_value_v2_units: uint256 = v1_balance * NEW_TOKENS_PER_NFT // LEGACY_TOKENS_PER_NFT
    assert migrated_value_v2_units + v2_balance == NEW_TOKENS_PER_NFT, "Invalid token balance after migration"
    
    # Log the successful migration
    log Migrated(
        user=msg.sender, 
        remy_v1_amount=balance, 
        remy_v2_amount=remy_v2_received, 
        nfts_redeemed=max_nfts,
        leftover_tokens_swapped=leftover_tokens
    )

# ERC721 receiver interface implementation
@external
def onERC721Received(operator: address, from_addr: address, tokenId: uint256, data: Bytes[1024]) -> bytes4:
    """
    @dev Handle the receipt of an NFT
    @return bytes4 selector to confirm token transfer
    """
    # Return the selector to confirm we can receive NFTs
    return 0x150b7a02
