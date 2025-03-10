# pragma version ^0.4.0

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from interfaces import IManagedVaultToken

################################################################################
# STATE VARIABLES
################################################################################

erc20: public(IERC20)
erc721: public(IERC721)
UNIT: constant(uint256) = 1000 * 10 ** 18

################################################################################
# EVENTS
################################################################################

event Deposit:
    recipient: indexed(address)
    token_ids: DynArray[uint256, 100]
    erc20_amt: uint256

event Withdraw:
    recipient: indexed(address)
    token_ids: DynArray[uint256, 100]
    erc20_amt: uint256

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(_token_address: address, erc721_address: address):
    self.erc721 = IERC721(erc721_address)
    self.erc20 = IERC20(_token_address)

################################################################################
# DEPOSIT FUNCTION
################################################################################

@nonreentrant
@external
def deposit(tokenIds: DynArray[uint256, 100], recipient: address = msg.sender) -> uint256:
    """
    Deposits one or more ERC721 tokens and mints the corresponding amount of ERC20 tokens.
    Can be used for single or batch deposits.
    """
    assert len(tokenIds) > 0, "Must deposit at least one token"
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    mint_amount: uint256 = self.mint_erc20(recipient, len(tokenIds))
    log Deposit(recipient, tokenIds, mint_amount)
    return mint_amount

################################################################################
# WITHDRAW FUNCTION
################################################################################

@nonreentrant
@external
def withdraw(tokenIds: DynArray[uint256, 100], recipient: address = msg.sender) -> uint256:
    """
    Withdraws one or more ERC721 tokens and burns the corresponding amount of ERC20 tokens.
    Can be used for single or batch withdrawals.
    """
    assert len(tokenIds) > 0, "Must withdraw at least one token"

    # Calculate token amount
    total_amount: uint256 = UNIT * len(tokenIds)
    
    # Verify vault owns all tokens before proceeding
    for tokenId: uint256 in tokenIds:
        assert staticcall self.erc721.ownerOf(tokenId) == self, "Vault does not own one of the tokens"
    
    # Burn tokens first
    self.burn_erc20(msg.sender, len(tokenIds))
    
    # Then transfer the NFTs
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
    
    log Withdraw(recipient, tokenIds, total_amount)
    return total_amount

################################################################################
# INTERNAL BURN/MINT HELPERS
################################################################################

@internal
def mint_erc20(recipient: address, num_tokens: uint256) -> uint256:
    erc20_amt: uint256 = num_tokens * UNIT
    extcall IManagedVaultToken(self.erc20.address).mint(recipient, erc20_amt)
    return erc20_amt

@internal
def burn_erc20(holder: address, num_tokens: uint256):
    erc20_amt: uint256 = num_tokens * UNIT
    extcall self.erc20.transferFrom(holder, self, erc20_amt)
    extcall IManagedVaultToken(self.erc20.address).burn(self, erc20_amt)

################################################################################
# EXTERNAL QUOTE FUNCTIONS
################################################################################

@pure
@external
def quoteDeposit(count: uint256) -> uint256:
    """
    Returns the amount of ERC20 tokens to be minted for a given number of ERC721 tokens.
    """
    return UNIT * count

@pure
@external
def quoteWithdraw(count: uint256) -> uint256:
    """
    Returns the amount of ERC20 tokens to be burned for a given number of ERC721 tokens.
    """
    return UNIT * count