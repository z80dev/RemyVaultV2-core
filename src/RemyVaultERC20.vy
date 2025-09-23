# pragma version ^0.4.3

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC721
from ethereum.ercs import IERC20
from interfaces import IManagedVaultToken

################################################################################
# MODULES
################################################################################

from snekmate.auth import ownable
from snekmate.tokens import erc20 as token

initializes: ownable
initializes: token[ ownable := ownable ]
exports: (
    token.balanceOf,
    token.totalSupply,
    token.transfer,
    token.transferFrom,
    token.approve,
    token.allowance,
    token.name,
    token.DOMAIN_SEPARATOR,
    token.eip712Domain,
          )

################################################################################
# STATE VARIABLES
################################################################################

erc721: public(IERC721)
UNIT: constant(uint256) = 1 * 10 ** 18

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
def __init__(name_: String[25], symbol_: String[5], erc721_address: address):
    ownable.__init__()
    token.__init__(name_, symbol_, 18, name_, "1.0")
    self.erc721 = IERC721(erc721_address)

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
    log Deposit(recipient=recipient, token_ids=tokenIds, erc20_amt=mint_amount)
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
    
    # Burn tokens first
    self.burn_erc20(msg.sender, len(tokenIds))
    
    # Then transfer the NFTs
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
    
    log Withdraw(recipient=recipient, token_ids=tokenIds, erc20_amt=total_amount)
    return total_amount

################################################################################
# INTERNAL BURN/MINT HELPERS
################################################################################

@internal
def mint_erc20(recipient: address, num_tokens: uint256) -> uint256:
    erc20_amt: uint256 = num_tokens * UNIT
    token._mint(recipient, erc20_amt)
    return erc20_amt

@internal
def burn_erc20(holder: address, num_tokens: uint256):
    erc20_amt: uint256 = num_tokens * UNIT
    token._burn(holder, erc20_amt)

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


@view
def erc20() -> IERC20:
    return IERC20(self)
