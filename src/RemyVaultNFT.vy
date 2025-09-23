# pragma version ^0.4.3
"""
@title RemyVaultNFT - ERC721 collection for Remy protocol NFTs
@license GNU Affero General Public License v3.0 only
"""

from snekmate.auth import ownable
from snekmate.tokens import erc721

initializes: ownable
initializes: erc721[ownable := ownable]

exports: (
    erc721.approve,
    erc721.balanceOf,
    erc721.burn,
    erc721.DOMAIN_SEPARATOR,
    erc721.eip712Domain,
    erc721.getApproved,
    erc721.isApprovedForAll,
    erc721.is_minter,
    erc721.name,
    erc721.nonces,
    erc721.owner,
    erc721.ownerOf,
    erc721.permit,
    erc721.renounce_ownership,
    erc721.safeTransferFrom,
    erc721.safe_mint,
    erc721.setApprovalForAll,
    erc721.set_minter,
    erc721.supportsInterface,
    erc721.symbol,
    erc721.tokenByIndex,
    erc721.tokenOfOwnerByIndex,
    erc721.tokenURI,
    erc721.totalSupply,
    erc721.transferFrom,
    erc721.transfer_ownership,
)


@deploy
def __init__(
    name_: String[25],
    symbol_: String[5],
    base_uri_: String[80],
    owner_: address
):
    """
    @dev Initializes the ERC721 collection.
    @param name_ Collection name.
    @param symbol_ Collection symbol.
    @param base_uri_ Base token URI prefix used when token-specific metadata is empty.
    @param owner_ Account that should receive ownership after deployment.
    """
    ownable.__init__()
    erc721.__init__(name_, symbol_, base_uri_, name_, "1.0")

    if owner_ != msg.sender:
        ownable._transfer_ownership(owner_)
