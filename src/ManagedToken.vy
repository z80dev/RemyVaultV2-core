# pragma version ~=0.4.0
"""
@title ManagedToken - Internal ERC20 token used by vaults for representing NFT value
@license GNU Affero General Public License v3.0 only
"""

# Import the ERC20 interface
from ethereum.ercs import IERC20
implements: IERC20

# Import the ERC20Detailed interface
from ethereum.ercs import IERC20Detailed
implements: IERC20Detailed

from snekmate.auth import ownable
from snekmate.tokens import erc20

initializes: ownable
initializes: erc20[ownable := ownable]

################################################################################
# EVENTS
################################################################################

event ManagerChanged:
    old_manager: indexed(address)
    new_manager: indexed(address)

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(name_: String[25], symbol_: String[5], manager_: address):
    """
    @dev Initializes the mvREMY token
    @param name_ The name of the token
    @param symbol_ The symbol of the token
    @param manager_ The address that can mint and burn tokens (typically the metavault)
    """
    ownable.__init__()
    erc20.__init__(name_, symbol_, 18, name_, "1.0")
    # Transfer ownership to the manager address
    ownable._transfer_ownership(manager_)

################################################################################
# MANAGER FUNCTIONS
################################################################################

@external
def mint(to: address, amount: uint256):
    """
    @dev Mints tokens to the specified address
    @param to The address that will receive the minted tokens
    @param amount The amount of tokens to mint
    """
    ownable._check_owner()
    erc20._mint(to, amount)


@external
def burn(from_: address, amount: uint256):
    """
    @dev Burns tokens from the specified address
    @param from_ The address from which tokens will be burned
    @param amount The amount of tokens to burn
    """
    ownable._check_owner()
    erc20._burn(from_, amount)

exports: (
    erc20.approve,
    erc20.balanceOf,
    erc20.allowance,
    erc20.name,
    erc20.symbol,
    erc20.decimals,
    erc20.totalSupply,
    erc20.transfer,
    erc20.transferFrom,
    ownable.owner,
    ownable.transfer_ownership,
    ownable.renounce_ownership,
)
