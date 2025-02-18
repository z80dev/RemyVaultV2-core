# pragma version ^0.4.0

from ethereum.ercs import IERC20

implements: IERC20

allowance: public(HashMap[address, HashMap[address, uint256]])
balanceOf: public(HashMap[address, uint256])
totalSupply: public(uint256)

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    amount: uint256

event Mint:
    to: indexed(address)
    amount: uint256

@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    log Approval(msg.sender, spender, amount)
    return True

@external
def transfer(to: address, amount: uint256) -> bool:
    assert self.balanceOf[msg.sender] >= amount
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[to] += amount
    log Transfer(msg.sender, to, amount)
    return True

@external
def transferFrom(_from: address, to: address, amount: uint256) -> bool:
    assert self.balanceOf[_from] >= amount
    assert self.allowance[_from][msg.sender] >= amount
    self.balanceOf[_from] -= amount
    self.balanceOf[to] += amount
    self.allowance[_from][msg.sender] -= amount
    log Transfer(_from, to, amount)
    return True

@external
def mint(amount: uint256):
    self.totalSupply += amount
    self.balanceOf[msg.sender] += amount
    log Mint(msg.sender, amount)

@external
def burn(amount: uint256):
    assert self.balanceOf[msg.sender] >= amount
    self.totalSupply -= amount
    self.balanceOf[msg.sender] -= amount
