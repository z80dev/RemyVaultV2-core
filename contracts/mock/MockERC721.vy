# pragma version ^0.4.0

from snekmate.auth import ownable
from snekmate.tokens import erc721

initializes: ownable
initializes: erc721[ownable := ownable]

@deploy
@payable
def __init__(
    name_: String[25], symbol_: String[5], base_uri_: String[80], name_eip712_: String[50], version_eip712_: String[20]
):
    ownable.__init__()
    erc721.__init__(name_, symbol_, base_uri_, name_eip712_, version_eip712_)
