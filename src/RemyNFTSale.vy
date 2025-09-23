# pragma version ^0.4.3
"""
@title RemyNFTSale - ERC20-denominated minting flow for RemyVaultNFT
@license GNU Affero General Public License v3.0 only
"""

from snekmate.auth import ownable
from ethereum.ercs import IERC20


interface IRemyVaultNFT:
    def safe_mint(owner: address, uri: String[432]): nonpayable
    def is_minter(account: address) -> bool: view


initializes: ownable

exports: (
    ownable.owner,
    ownable.transfer_ownership,
    ownable.renounce_ownership,
)

MAX_BATCH_SIZE: constant(uint256) = 64

nft: public(address)
payment_token: public(address)
price: public(uint256)
funds_recipient: public(address)
default_token_uri: public(String[432])

event Purchase:
    buyer: indexed(address)
    recipient: indexed(address)
    quantity: uint256
    total_paid: uint256

event PriceUpdated:
    old_price: uint256
    new_price: uint256

event PaymentTokenUpdated:
    previous_token: address
    new_token: address

event FundsRecipientUpdated:
    previous_recipient: address
    new_recipient: address

event DefaultTokenURISet:
    new_uri: String[432]




@deploy
def __init__(
    nft_: address,
    payment_token_: address,
    price_: uint256,
    funds_recipient_: address,
    default_token_uri_: String[432]
):
    """
    @dev Configures the sale contract.
    @param nft_ ERC721 collection that will be minted.
    @param payment_token_ ERC20 accepted as payment.
    @param price_ Unit price denominated in `payment_token_` for each NFT minted.
    @param funds_recipient_ Destination for collected ERC20. Defaults to contract owner when zero.
    @param default_token_uri_ Metadata suffix forwarded to the NFT contract during minting.
    """
    ownable.__init__()

    assert nft_ != empty(address), "RemyNFTSale: nft address zero"
    assert payment_token_ != empty(address), "RemyNFTSale: payment token zero"

    self.nft = nft_
    self.payment_token = payment_token_
    self.price = price_

    if funds_recipient_ == empty(address):
        self.funds_recipient = msg.sender
    else:
        self.funds_recipient = funds_recipient_

    self.default_token_uri = default_token_uri_


@external
def set_price(new_price: uint256):
    """
    @dev Updates the NFT unit price.
    @param new_price The new payment amount required per NFT.
    """
    ownable._check_owner()
    old_price: uint256 = self.price
    self.price = new_price
    log PriceUpdated(old_price=old_price, new_price=new_price)


@external
def set_payment_token(new_token: address):
    """
    @dev Updates the ERC20 used for payments.
    @param new_token ERC20 token address.
    """
    ownable._check_owner()
    assert new_token != empty(address), "RemyNFTSale: payment token zero"

    previous_token: address = self.payment_token
    self.payment_token = new_token
    log PaymentTokenUpdated(previous_token=previous_token, new_token=new_token)


@external
def set_funds_recipient(new_recipient: address):
    """
    @dev Updates the destination for collected funds.
    @param new_recipient Address that will receive ERC20 proceeds.
    """
    ownable._check_owner()
    assert new_recipient != empty(address), "RemyNFTSale: funds recipient zero"

    previous_recipient: address = self.funds_recipient
    self.funds_recipient = new_recipient
    log FundsRecipientUpdated(previous_recipient=previous_recipient, new_recipient=new_recipient)


@external
def set_default_token_uri(new_uri: String[432]):
    """
    @dev Updates the metadata suffix passed to the NFT contract.
    @param new_uri Token URI suffix.
    """
    ownable._check_owner()
    self.default_token_uri = new_uri
    log DefaultTokenURISet(new_uri=new_uri)


@external
@view
def price_for(amount: uint256) -> uint256:
    """
    @dev Helper returning the aggregate cost for `amount` NFTs at the current price.
    @param amount Desired purchase amount.
    @return Total ERC20 payment required.
    """
    return amount * self.price


@external
def purchase(recipient: address, amount: uint256):
    """
    @dev Purchases `amount` NFTs on behalf of `recipient` using permitted ERC20.
    @param recipient Mint recipient.
    @param amount Number of NFTs to mint.
    """
    self._purchase(recipient, amount)


@external
def purchase_self(amount: uint256):
    """
    @dev Purchases `amount` NFTs for the caller.
    @param amount Number of NFTs to mint.
    """
    self._purchase(msg.sender, amount)


@external
def sweep_erc20(token: address, recipient: address, amount: uint256):
    """
    @dev Allows the owner to recover arbitrary ERC20 tokens held by this contract.
    @param token ERC20 token to transfer.
    @param recipient Destination address.
    @param amount Amount to transfer.
    """
    ownable._check_owner()
    assert recipient != empty(address), "RemyNFTSale: sweep recipient zero"

    success: bool = extcall IERC20(token).transfer(recipient, amount)
    assert success, "RemyNFTSale: sweep transfer failed"


@internal
def _purchase(recipient: address, amount: uint256):
    assert recipient != empty(address), "RemyNFTSale: recipient zero"
    assert amount != 0, "RemyNFTSale: amount zero"
    assert amount <= MAX_BATCH_SIZE, "RemyNFTSale: amount exceeds batch limit"
    assert staticcall IRemyVaultNFT(self.nft).is_minter(self), "RemyNFTSale: not authorised minter"

    total_cost: uint256 = amount * self.price

    if total_cost != 0:
        success: bool = extcall IERC20(self.payment_token).transferFrom(msg.sender, self.funds_recipient, total_cost)
        assert success, "RemyNFTSale: payment transfer failed"

    token_uri: String[432] = self.default_token_uri
    for i: uint256 in range(amount, bound=MAX_BATCH_SIZE):  # Bounded to protect gas usage.
        extcall IRemyVaultNFT(self.nft).safe_mint(recipient, token_uri)

    log Purchase(buyer=msg.sender, recipient=recipient, quantity=amount, total_paid=total_cost)
