# pragma version ^0.4.3
# Contract that handles compound actions on behalf of users
# Focused on facilitating migration from RemyVault V1 to V2
# Lets expose methods to convert anything the user could have
# into relevant remy vault v2 outputs
#
# User can be holding (inputs):
# - NFTs (v1 or v2)
# - RemyVault V1 shares (rbREMY)
# - Staked RemyVault V1 shares (rbREMYLS)
# - ETH
# - Arbitrary ERC20
#
# User can want to receive (outputs):
# - NFTs (v1 or v2)
# - RemyVault V2 shares (REMY) (aka newremy)
# - ETH
# - Arbitrary ERC20
# - LP tokens

from ethereum.ercs import IERC20 as ERC20

from interfaces import LegacyRemyVault as RemyVault
from interfaces import DN404
from interfaces import InventoryERC721
from interfaces import VaultERC4626
from interfaces import RemyVault as RemyVaultV2

from snekmate.auth import ownable

from modules import vault_owner

initializes: ownable
initializes: vault_owner[ownable := ownable]

# these are the contracts we'll interact with
erc4626: public(VaultERC4626)
# - balanceOf
# - convertToShares
# - transferFrom
# - withdraw
erc721: public(InventoryERC721)
erc20_v1: public(DN404)
vault_v2: public(RemyVaultV2)
erc20_v2: public(ERC20)

@deploy
def __init__(old_router: address, vault_v2: address):
    ownable.__init__()
    vault_owner.__init__(old_router)

    self.erc4626 = VaultERC4626(vault_owner.erc4626_address)

    erc721_address: address = staticcall vault_owner.vault.erc721()
    self.erc721 = InventoryERC721(erc721_address)

    erc20_address: address = staticcall vault_owner.vault.erc20()
    self.erc20_v1 = DN404(erc20_address)

    self.vault_v2 = RemyVaultV2(vault_v2)
    self.erc20_v2 = ERC20(staticcall self.vault_v2.erc20())

    # approve vault for all erc721 transfers
    extcall self.erc721.setApprovalForAll(vault_owner.vault.address, True)
    extcall self.erc721.setApprovalForAll(self.vault_v2.address, True)


@external
def unstake_inventory(recipient: address, token_ids: DynArray[uint256, 100]):
    """
    Unstakes an NFT from the vault
    """
    # Turn on vault
    vault_owner._enable_vault()

    # Get starting balance of ERC4626 shares (prevent stealing)
    start_bal: uint256 = staticcall self.erc4626.balanceOf(self)

    # Calculate required shares to burn
    tokens_required: uint256 = staticcall vault_owner.vault.quote_redeem(len(token_ids), False)
    shares_required: uint256 = staticcall self.erc4626.convertToShares(tokens_required) + 1

    # Take and withdraw shares (should be combined?)
    extcall self.erc4626.transferFrom(msg.sender, self, shares_required)
    extcall self.erc4626.withdraw(tokens_required, self, self)

    # Approve and redeem NFTs
    extcall self.erc20_v1.approve(vault_owner.vault.address, tokens_required)
    extcall vault_owner.vault.redeem_batch(token_ids, recipient, False)

    # Return any leftover shares
    if staticcall self.erc4626.balanceOf(self) > start_bal:
        extcall self.erc4626.transfer(recipient, staticcall self.erc4626.balanceOf(self) - start_bal)
    vault_owner._disable_vault()

event TokensSwappedForNFTs:
    swapper: indexed(address)
    tokens_in: uint256
    nfts_out_count: uint256
    fee: uint256

event V2TokensSwappedForV1NFTs:
    swapper: indexed(address)
    tokens_in: uint256
    nfts_supplied_count: uint256
    nfts_out_count: uint256
    leftover_tokens: uint256

event V1TokensConvertedToV2:
    swapper: indexed(address)
    tokens_in: uint256
    tokens_out: uint256
    minted: uint256
    buffer_used: uint256


@external
def swap_tokens_for_nfts(tokenIds: DynArray[uint256, 100], recipient: address):
    """
    Swaps vault tokens for NFTs directly, without requiring ETH payment
    User must have approved this contract to spend their tokens
    """
    extcall vault_owner.vault.set_active(True)

    # Calculate total tokens required (including redeem fee)
    tokens_required: uint256 = staticcall vault_owner.vault.quote_redeem(len(tokenIds), False)

    # Transfer tokens from user to this contract
    extcall self.erc20_v1.transferFrom(msg.sender, self, tokens_required)

    # Approve vault to spend the tokens
    extcall self.erc20_v1.approve(vault_owner.vault.address, tokens_required)

    # Redeem the NFTs
    amt_redeemed: uint256 = extcall vault_owner.vault.redeem_batch(tokenIds, recipient, False)
    
    # Log the transaction
    log TokensSwappedForNFTs(swapper=msg.sender, tokens_in=tokens_required, nfts_out_count=len(tokenIds), fee=tokens_required - (len(tokenIds) * 1000))
    
    extcall vault_owner.vault.set_active(False)

@external
def swap_vault_tokens_for_nfts(tokenIds_v2: DynArray[uint256, 100], tokenIds_v1: DynArray[uint256, 100], recipient: address):
    """
    Redeems Vault V2 inventory directly and sources Vault V1 NFTs via swap using additional V2 redemptions
    Caller must approve the MigratorRouter to spend the required ERC20 V2 amount
    """
    total_targets: uint256 = len(tokenIds_v2) + len(tokenIds_v1)
    assert total_targets > 0, "no target NFTs provided"

    tokens_required_direct: uint256 = staticcall self.vault_v2.quoteWithdraw(len(tokenIds_v2))
    tokens_required_supply: uint256 = staticcall self.vault_v2.quoteWithdraw(len(tokenIds_v1))
    tokens_required_total: uint256 = tokens_required_direct + tokens_required_supply

    extcall self.erc20_v2.transferFrom(msg.sender, self, tokens_required_total)

    tokens_burned_total: uint256 = 0
    leftover_tokens: uint256 = 0

    if len(tokenIds_v2) > 0:
        extcall self.erc20_v2.approve(self.vault_v2.address, tokens_required_direct)
        burned_direct: uint256 = extcall self.vault_v2.withdraw(tokenIds_v2, recipient)
        tokens_burned_total += burned_direct

    if len(tokenIds_v1) > 0:
        available_v2: uint256 = staticcall self.erc721.balanceOf(self.vault_v2.address)
        assert available_v2 >= len(tokenIds_v1), "insufficient V2 inventory"

        supply_tokenIds: DynArray[uint256, 100] = []
        for idx: uint256 in range(available_v2, bound=1000):
            candidate: uint256 = staticcall self.erc721.tokenOfOwnerByIndex(self.vault_v2.address, idx)
            supply_tokenIds.append(candidate)
            if len(supply_tokenIds) == len(tokenIds_v1):
                break
        assert len(supply_tokenIds) == len(tokenIds_v1), "insufficient V2 supply for swap"

        extcall self.erc20_v2.approve(self.vault_v2.address, tokens_required_supply)
        tokens_burned_supply: uint256 = extcall self.vault_v2.withdraw(supply_tokenIds, self)
        tokens_burned_total += tokens_burned_supply

        extcall vault_owner.vault.set_active(True)
        bal_before_v1: uint256 = staticcall self.erc20_v1.balanceOf(self)
        extcall self.erc20_v1.setSkipNFT(True)
        amt_minted_v1: uint256 = extcall vault_owner.vault.mint_batch(supply_tokenIds, self, False)
        bal_after_v1: uint256 = staticcall self.erc20_v1.balanceOf(self)
        assert bal_after_v1 - bal_before_v1 == amt_minted_v1, "minted V1 token mismatch"

        tokens_needed_v1: uint256 = staticcall vault_owner.vault.quote_redeem(len(tokenIds_v1), False)
        assert amt_minted_v1 >= tokens_needed_v1, "insufficient legacy liquidity"
        extcall self.erc20_v1.approve(vault_owner.vault.address, amt_minted_v1)
        amt_redeemed_v1: uint256 = extcall vault_owner.vault.redeem_batch(tokenIds_v1, recipient, False)

        if amt_minted_v1 > amt_redeemed_v1:
            leftover_tokens = amt_minted_v1 - amt_redeemed_v1
            extcall self.erc20_v1.transfer(recipient, leftover_tokens)

        extcall vault_owner.vault.set_active(False)

    assert tokens_burned_total == tokens_required_total, "vault v2 withdrawal mismatch"

    log V2TokensSwappedForV1NFTs(
        swapper=msg.sender,
        tokens_in=tokens_required_total,
        nfts_supplied_count=len(tokenIds_v1),
        nfts_out_count=len(tokenIds_v1) + len(tokenIds_v2),
        leftover_tokens=leftover_tokens
    )

@external
def onERC721Received(operator: address, from_addr: address, tokenId: uint256, data: Bytes[256]) -> bytes4:
    """
    Accept ERC721 transfers required for migration flows
    """
    return 0x150b7a02

@external
def convert_v1_tokens_to_v2(legacy_token_amount: uint256, recipient: address) -> uint256:
    """
    Converts Vault V1 tokens into Vault V2 ERC20 by cycling through the shared NFT inventory
    Caller supplies the amount of legacy tokens to burn; the contract determines how many NFTs it can cycle
    Returns any legacy token remainder that could not be matched to a full NFT
    """
    assert legacy_token_amount > 0, "no tokens supplied"

    # TODO: can remove this on next deployment
    extcall vault_owner.vault.set_fee_exempt(self, True)

    legacy_vault_addr: address = vault_owner.vault.address
    available_inventory: uint256 = staticcall self.erc721.balanceOf(legacy_vault_addr)
    assert available_inventory > 0, "insufficient legacy inventory"

    max_nfts: uint256 = available_inventory
    if max_nfts > 100:
        max_nfts = 100

    num_nfts: uint256 = legacy_token_amount // (1000 * 10 ** 18)
    tokens_required: uint256 = staticcall vault_owner.vault.quote_redeem(num_nfts, False)

    assert num_nfts > 0, "insufficient tokens"

    tokenIds: DynArray[uint256, 100] = []
    for idx: uint256 in range(num_nfts, bound=100):
        token_id: uint256 = staticcall self.erc721.tokenOfOwnerByIndex(legacy_vault_addr, idx)
        tokenIds.append(token_id)

    extcall self.erc20_v1.transferFrom(msg.sender, self, tokens_required)
    vault_owner._enable_vault()
    extcall self.erc20_v1.approve(vault_owner.vault.address, tokens_required)
    extcall vault_owner.vault.redeem_batch(tokenIds, self, False)

    tokens_out_target: uint256 = staticcall self.vault_v2.quoteWithdraw(num_nfts)
    minted_v2: uint256 = extcall self.vault_v2.deposit(tokenIds, self)

    total_balance_v2: uint256 = staticcall self.erc20_v2.balanceOf(self)
    assert total_balance_v2 >= tokens_out_target, "insufficient V2 liquidity"
    extcall self.erc20_v2.transfer(recipient, tokens_out_target)

    buffer_used: uint256 = 0
    if minted_v2 < tokens_out_target:
        buffer_used = tokens_out_target - minted_v2

    log V1TokensConvertedToV2(
        swapper=msg.sender,
        tokens_in=tokens_required,
        tokens_out=tokens_out_target,
        minted=minted_v2,
        buffer_used=buffer_used
    )

    vault_owner._disable_vault()

    return legacy_token_amount - tokens_required

@view
@external
def quote_tokens_for_nfts(tokenIds: DynArray[uint256, 100]) -> uint256:
    """
    Returns the amount of vault tokens required to redeem the specified NFTs
    Includes any applicable redeem fees
    """
    return staticcall vault_owner.vault.quote_redeem(len(tokenIds), False)

@view
@external
def quote_v2_tokens_for_v1_nfts(num_nfts: uint256) -> uint256:
    """
    Returns the amount of ERC20 V2 required to source the requested number of Vault V1 NFTs
    """
    return staticcall self.vault_v2.quoteWithdraw(num_nfts)

@view
@external
def quote_convert_v1_tokens_to_v2(num_nfts: uint256) -> uint256:
    """
    Helper for frontends to determine the Vault V1 token burn required for conversion
    """
    return staticcall vault_owner.vault.quote_redeem(num_nfts, False)

@payable
@external
def __default__():
    pass

exports: ownable.__interface__
exports: vault_owner.__interface__
