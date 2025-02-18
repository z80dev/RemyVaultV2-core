# pragma version ^0.4.0

from ethereum.ercs import IERC20

owner: address

@deploy
def __init__():
    self.owner = msg.sender


@external
def pull_rewards(amount: uint256, token: address):
    extcall IERC20(token).transferFrom(msg.sender, self, amount)
