# pragma version ^0.4.0

from snekmate.auth import ownable as ow
initializes: ow

from snekmate.tokens import erc721
initializes: erc721[ownable := ow]

@deploy
@payable
def __init__(
    name_: String[25], symbol_: String[5], base_uri_: String[80], name_eip712_: String[50], version_eip712_: String[20]
):
    ow.__init__()
    erc721.__init__(name_, symbol_, base_uri_, name_eip712_, version_eip712_)

@external
def mint(to: address, token_id: uint256):
    ow._check_owner()
    erc721._mint(to, token_id)

exports: erc721.__interface__
