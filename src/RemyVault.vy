# pragma version ^0.4.0

from ethereum.ercs import IERC20 as ERC20
from ethereum.ercs import IERC721 as ERC721

erc20: public(ERC20)
erc721: public(ERC721)

event Minted:
    recipient: indexed(address)
    token_id: indexed(uint256)
    erc20_amt: uint256

event Redeemed:
    recipient: indexed(address)
    token_id: indexed(uint256)
    erc20_amt: uint256

interface IManagedToken:
    def mint(to: address, amount: uint256): nonpayable
    def burn(amount: uint256): nonpayable

UNIT: constant(uint256) = 1000 * 10 ** 18

@deploy
def __init__(_token_address: address, erc721_address: address):
    self.erc721 = ERC721(erc721_address)
    self.erc20 = ERC20(_token_address)

@internal
def mint_erc20(recipient: address, num_tokens: uint256) -> uint256:
    erc20_amt: uint256 = num_tokens * UNIT
    extcall IManagedToken(self.erc20.address).mint(recipient, erc20_amt)
    return erc20_amt

@nonreentrant
@external
def deposit(tokenId: uint256, recipient: address = msg.sender):
    extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    self.mint_erc20(recipient, 1)
    log Minted(recipient, tokenId, UNIT)

@nonreentrant
@external
def batchDeposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256:
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    mint_amount: uint256 = self.mint_erc20(recipient, len(tokenIds))
    for tokenId: uint256 in tokenIds:
        log Minted(recipient, tokenId, UNIT)
    return mint_amount

@nonreentrant
@external
def withdraw(tokenId: uint256, recipient: address = msg.sender):
    extcall self.erc20.transferFrom(msg.sender, self, UNIT)
    extcall IManagedToken(self.erc20.address).burn(UNIT)
    extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
    log Redeemed(recipient, tokenId, UNIT)

@nonreentrant
@external
def batchWithdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256:
    total_amount: uint256 = UNIT * len(tokenIds)
    extcall self.erc20.transferFrom(msg.sender, self, total_amount)
    extcall IManagedToken(self.erc20.address).burn(UNIT * len(tokenIds))
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
        log Redeemed(recipient, tokenId, UNIT)
    return total_amount

@pure
@external
def quoteDeposit(count: uint256) -> uint256:
    return UNIT * count
