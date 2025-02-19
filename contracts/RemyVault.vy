# pragma version ^0.4.0
#
# This contract accepts tokens of an ERC721 collection and issues 1000 tokens of an ERC20 for each token received.
# The ERC20 tokens are minted by the contract and sent to the sender of the ERC721 token.

from ethereum.ercs import IERC20 as ERC20
from ethereum.ercs import IERC721 as ERC721

erc20: public(ERC20)
erc721: public(ERC721)

active: public(bool)

owner: public(address)

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

event FeeExemptSet:
    addr: indexed(address)
    is_exempt: indexed(bool)

event FeeReceiverSet:
    receiver: indexed(address)

event FeesSet:
    mint_fee: indexed(uint256)
    redeem_fee: indexed(uint256)

event ActiveSet:
    active: indexed(bool)

event Minted:
    recipient: indexed(address)
    token_id: indexed(uint256)
    erc20_amt: uint256
    fee: uint256

event Redeemed:
    recipient: indexed(address)
    token_id: indexed(uint256)
    erc20_amt: uint256
    fee: uint256

mint_fee: public(uint256)
redeem_fee: public(uint256)

rbtoken_fee_receiver: public(address)

interface RewardsProvider:
    def distribute(): nonpayable

interface RewardsPuller:
    def pull_rewards(amount: uint256, token: address): nonpayable

interface IManagedToken:
    def mint(to: address, amount: uint256): nonpayable
    def burn(amount: uint256): nonpayable

implements: RewardsProvider

UNIT: constant(uint256) = 1000 * 10 ** 18

fee_exempt: public(HashMap[address, bool])

pending_fee: public(uint256)

interface DN404:
    def setSkipNFT(skip: bool) -> bool: nonpayable
    def setBaseURI(uri: String[128]): nonpayable

@deploy
def __init__(_token_address: address, erc721_address: address, fees: uint256[2]):
    self.erc721 = ERC721(erc721_address)
    self.erc20 = ERC20(_token_address)
    extcall DN404(_token_address).setSkipNFT(True)
    self.active = True
    self.owner = msg.sender
    self.mint_fee = fees[0] * 10 ** 18
    self.redeem_fee = fees[1] * 10 ** 18
    self.rbtoken_fee_receiver = msg.sender

@nonreentrant
@external
def set_base_uri(uri: String[128]):
    assert msg.sender == self.owner, "Only owner can set base URI"
    extcall DN404(self.erc20.address).setBaseURI(uri)

@nonreentrant
@external
def mint_fee_for(addr: address, num_tokens: uint256) -> uint256:
    return self._mint_fee(addr, num_tokens)

@nonreentrant
@external
def redeem_fee_for(addr: address, num_tokens:uint256) -> uint256:
    return self._redeem_fee(addr, num_tokens)

@nonreentrant
@external
def charge_fee(amt: uint256):
    self.pending_fee += amt
    extcall self.erc20.transferFrom(msg.sender, self, amt)

@nonreentrant
@external
def distribute():
    to_pay: uint256 = self.pending_fee
    self.pending_fee = 0
    extcall self.erc20.approve(self.rbtoken_fee_receiver, to_pay)
    extcall RewardsPuller(self.rbtoken_fee_receiver).pull_rewards(to_pay, self.erc20.address)

@internal
def mint_erc20_for_erc721(token_id: uint256, receiver: address):
    extcall IManagedToken(self.erc20.address).mint(self, UNIT)

@view
@internal
def _mint_fee(addr: address, num_tokens: uint256) -> uint256:
    if self.fee_exempt[addr]:
        return 0
    return num_tokens * self.mint_fee

@view
@internal
def _redeem_fee(addr: address, num_tokens: uint256 = 1) -> uint256:
    if self.fee_exempt[addr]:
        return 0
    return self.redeem_fee * num_tokens

@internal
def mint_erc20_with_fee(recipient: address, num_tokens: uint256, force_fee: bool = False) -> uint256:
    erc20_amt: uint256 = num_tokens * UNIT
    fee: uint256 = self._mint_fee(recipient, num_tokens)
    if fee == 0 and force_fee:
        fee = self.mint_fee * num_tokens
    extcall IManagedToken(self.erc20.address).mint(self, erc20_amt)
    extcall self.erc20.transfer(recipient, erc20_amt - fee)
    if fee > 0:
        self.pending_fee += fee
    return erc20_amt - fee

@nonreentrant
@external
def mint(tokenId: uint256, recipient: address = msg.sender):
    assert self.active, "Contract is not active"
    extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    self.mint_erc20_with_fee(recipient, 1)
    log Minted(recipient, tokenId, UNIT, self._mint_fee(recipient, 1))

@nonreentrant
@external
def mint_batch(tokenIds: DynArray[uint256, 1000], recipient: address, force_fee: bool = False) -> uint256:
    assert self.active, "Contract is not active"
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.transferFrom(msg.sender, self, tokenId)
    mint_amount: uint256 = self.mint_erc20_with_fee(recipient, len(tokenIds), force_fee)
    for tokenId: uint256 in tokenIds:
        log Minted(recipient, tokenId, UNIT, self._mint_fee(recipient, 1))
    return mint_amount

@nonreentrant
@external
def redeem(tokenId: uint256, recipient: address = msg.sender):
    assert self.active, "Contract is not active"
    fee: uint256 = self._redeem_fee(msg.sender)
    self.pending_fee += fee
    extcall self.erc20.transferFrom(msg.sender, self, UNIT + fee)
    extcall IManagedToken(self.erc20.address).burn(UNIT)
    extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
    log Redeemed(recipient, tokenId, UNIT, fee)

@nonreentrant
@external
def redeem_batch(tokenIds: DynArray[uint256, 1000], recipient: address, force_fee: bool = False) -> uint256:
    assert self.active, "Contract is not active"
    fee: uint256 = 0
    if force_fee:
        fee = self.redeem_fee * len(tokenIds)
    else:
        fee  = self._redeem_fee(msg.sender, len(tokenIds))
    self.pending_fee += fee
    total_amount: uint256 = UNIT * len(tokenIds) + fee
    extcall self.erc20.transferFrom(msg.sender, self, total_amount)
    extcall IManagedToken(self.erc20.address).burn(UNIT * len(tokenIds))
    for tokenId: uint256 in tokenIds:
        extcall self.erc721.safeTransferFrom(self, recipient, tokenId)
        log Redeemed(recipient, tokenId, UNIT, fee)
    return total_amount


@view
@external
def quote_mint_fee(recipient: address, num_tokens: uint256) -> uint256:
    return self._mint_fee(recipient, num_tokens)

@view
@external
def quote_redeem_fee(recipient: address, num_tokens: uint256) -> uint256:
    return self._redeem_fee(recipient, num_tokens)

@view
@external
def quote_redeem(count: uint256, with_fee: bool = True) -> uint256:
    fee: uint256 = 0
    if with_fee:
        fee = self.redeem_fee * count
    return UNIT * count + fee

@view
@external
def quote_mint(count: uint256, with_fee: bool = True) -> uint256:
    fee: uint256 = 0
    if with_fee:
        fee = self.mint_fee * count
    return UNIT * count - fee

@external
def onERC721Received(operator: address, _from: address, tokenId: uint256, data: Bytes[256]) -> bytes4:
    assert self.active, "Contract is not active"
    self.mint_erc20_with_fee(_from, 1)
    log Minted(_from, tokenId, UNIT, self._mint_fee(_from, 1))
    return method_id("onERC721Received(address,address,uint256,bytes)", output_type=bytes4)

@external
def transfer_owner(new_owner: address):
    assert msg.sender == self.owner, "Only owner can transfer ownership"
    self.owner = new_owner
    log OwnershipTransferred(self.owner, new_owner)

@external
def set_fees(fees: uint256[2]):
    assert msg.sender == self.owner, "Only owner can set fees"
    self.mint_fee = fees[0] * 10 ** 18
    self.redeem_fee = fees[1] * 10 ** 18
    log FeesSet(fees[0], fees[1])

@external
def set_active(active: bool):
    assert msg.sender == self.owner, "Only owner can set active"
    self.active = active
    log ActiveSet(active)

@external
def set_fee_exempt(exempt: address, is_exempt: bool):
    assert msg.sender == self.owner, "Only owner can set fee exemption"
    self.fee_exempt[exempt] = is_exempt
    log FeeExemptSet(exempt, is_exempt)

@external
def set_rbtoken_fee_receiver(receiver: address):
    assert msg.sender == self.owner, "Only owner can set fee receiver"
    self.rbtoken_fee_receiver = receiver
    log FeeReceiverSet(receiver)
