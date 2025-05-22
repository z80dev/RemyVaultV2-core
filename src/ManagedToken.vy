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

################################################################################
# EVENTS
################################################################################

event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

event ManagerChanged:
    old_manager: indexed(address)
    new_manager: indexed(address)

################################################################################
# STATE VARIABLES
################################################################################

# ERC20 standard variables
name: public(String[25])
symbol: public(String[8])
decimals: public(uint8)
totalSupply: public(uint256)

# ERC20 balances and allowances
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

# Manager address that can mint and burn tokens
manager: public(address)

################################################################################
# CONSTRUCTOR
################################################################################

@deploy
def __init__(name_: String[25], symbol_: String[8], manager_: address):
    """
    @dev Initializes the mvREMY token
    @param name_ The name of the token
    @param symbol_ The symbol of the token
    @param manager_ The address that can mint and burn tokens (typically the metavault)
    """
    self.name = name_
    self.symbol = symbol_
    self.decimals = 18
    self.manager = manager_
    self.totalSupply = 0

################################################################################
# ERC20 FUNCTIONS
################################################################################

@external
def transfer(_to: address, _value: uint256) -> bool:
    """
    @dev Transfer tokens to a specified address
    @param _to The address to transfer to
    @param _value The amount to be transferred
    @return Success of the operation
    """
    assert _to != empty(address), "ERC20: transfer to zero address"
    assert self.balanceOf[msg.sender] >= _value, "ERC20: insufficient balance"
    
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    
    log Transfer(msg.sender, _to, _value)
    return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    """
    @dev Transfer tokens from one address to another
    @param _from Address to transfer from
    @param _to Address to transfer to
    @param _value Amount to transfer
    @return Success of the operation
    """
    assert _from != empty(address), "ERC20: transfer from zero address"
    assert _to != empty(address), "ERC20: transfer to zero address"
    assert self.balanceOf[_from] >= _value, "ERC20: insufficient balance"
    assert self.allowance[_from][msg.sender] >= _value, "ERC20: insufficient allowance"
    
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    self.allowance[_from][msg.sender] -= _value
    
    log Transfer(_from, _to, _value)
    return True

@external
def approve(_spender: address, _value: uint256) -> bool:
    """
    @dev Approve the passed address to spend the specified amount of tokens
    @param _spender The address which will spend the funds
    @param _value The amount of tokens to be spent
    @return Success of the operation
    """
    assert _spender != empty(address), "ERC20: approve to zero address"
    
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True

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
    assert msg.sender == self.manager, "Only manager can mint"
    assert to != empty(address), "ERC20: mint to zero address"
    
    self.totalSupply += amount
    self.balanceOf[to] += amount
    
    log Transfer(empty(address), to, amount)

@external
def burn(from_: address, amount: uint256):
    """
    @dev Burns tokens from the specified address
    @param from_ The address from which tokens will be burned
    @param amount The amount of tokens to burn
    """
    assert msg.sender == self.manager, "Only manager can burn"
    assert self.balanceOf[from_] >= amount, "ERC20: burn amount exceeds balance"
    
    self.balanceOf[from_] -= amount
    self.totalSupply -= amount
    
    log Transfer(from_, empty(address), amount)

@external
def change_manager(new_manager: address):
    """
    @dev Changes the manager address
    @param new_manager The new manager address
    """
    assert msg.sender == self.manager, "Only current manager can change manager"
    assert new_manager != empty(address), "New manager cannot be zero address"
    
    old_manager: address = self.manager
    self.manager = new_manager
    
    log ManagerChanged(old_manager, new_manager)
