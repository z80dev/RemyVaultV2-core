# pragma version ^0.4.0

from snekmate.auth import ownable
from snekmate.tokens import erc20

initializes: ownable
initializes: erc20[ownable := ownable]

@deploy
@payable
def __init__(
    name_: String[25], symbol_: String[5], decimals_: uint8, name_eip712_: String[50], version_eip712_: String[20]
):
    ownable.__init__()
    erc20.__init__(name_, symbol_, decimals_, name_eip712_, version_eip712_)

@external
def setSkipNFT(bool_: bool) -> bool:
    return True

exports: erc20.__interface__
