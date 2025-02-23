# pragma version ^0.4.0

################################################################################
# INTERFACE IMPORTS
################################################################################

from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from interfaces import ManagedToken as IManagedToken

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
# DEPOSIT FUNCTIONS
################################################################################

@nonreentrant
@external
def deposit(tokenId: uint256, recipient: address = msg.sender):
    """
    Deposits an ERC721 token and mints the corresponding amount of ERC20 tokens.
    """
    extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    self.mint_erc20(recipient, 1)
    log Deposit(recipient, [tokenId], UNIT)

@nonreentrant
@external
def batchDeposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256:
    """
    Deposits multiple ERC721 tokens and mints the corresponding amount of ERC20 tokens.
    """
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    mint_amount: uint256 = self.mint_erc20(recipient, len(tokenIds))
    log Deposit(recipient, tokenIds, mint_amount)
    return mint_amount

################################################################################
# WITHDRAW FUNCTIONS
################################################################################

@nonreentrant
@external
def withdraw(tokenId: uint256, recipient: address = msg.sender):
    """
    Withdraws an ERC721 token and burns the corresponding amount of ERC20 tokens.
    """
    self.burn_erc20(msg.sender, 1)
    extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
    log Withdraw(recipient, [tokenId], UNIT)

@nonreentrant
@external
def batchWithdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256:
    """
    Withdraws multiple ERC721 tokens and burns the corresponding amount of ERC20 tokens.
    """
    total_amount: uint256 = UNIT * len(tokenIds)
    self.burn_erc20(msg.sender, len(tokenIds))
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
    extcall IManagedToken(self.erc20.address).mint(recipient, erc20_amt)
    return erc20_amt

@internal
def burn_erc20(holder: address, num_tokens: uint256):
    extcall self.erc20.transferFrom(holder, self, num_tokens * UNIT)
    extcall IManagedToken(self.erc20.address).burn(num_tokens * UNIT)

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
