# pragma version ^0.4.0
#
# This contract distributes rewards to recipients
# Recipients *MUST* implement the RewardsPuller interface

### IMPORTS

from ethereum.ercs import IERC20

### INTERFACES
interface RewardsPuller:
    def pull_rewards(amount: uint256, token: address): nonpayable

interface RewardsProvider:
    def distribute(): nonpayable

implements: RewardsPuller
implements: RewardsProvider

### STATE VARIABLES
owner: public(address)

## External Contracts
token: public(IERC20)
source: public(address)
treasury: public(address)

## Recipient State
total_points: public(uint256)
points: HashMap[address, uint256]
recipients: DynArray[address, 10]

### EVENTS
event Distribution:
    recipient: indexed(address)
    amount: uint256

event RecipientAdded:
    recipient: address
    points: uint256

event TotalDistribution:
    amount: uint256

event RecipientModified:
    recipient: address
    points: uint256

### CONSTRUCTOR
@deploy
def __init__(token_address: address, treasury_address: address, source_address: address):
    self.owner = msg.sender
    self.total_points = 0
    self.token = IERC20(token_address)
    self.treasury = treasury_address
    self.source = source_address

### INTERNAL FUNCTIONS
@internal
def distribute_accumulated_rewards():
    balance: uint256 = staticcall self.token.balanceOf(self)
    if balance == 0:
        return
    for recipient: address in self.recipients:
        if self.points[recipient] == 0:
            continue
        amount: uint256 = balance * self.points[recipient] // self.total_points
        if amount > 0:
            extcall self.token.approve(recipient, amount)
            extcall RewardsPuller(recipient).pull_rewards(amount, self.token.address)
            log Distribution(recipient, amount)
    # send any dust to the treasury
    post_balance: uint256 = staticcall self.token.balanceOf(self)
    extcall self.token.transfer(self.treasury, post_balance)
    log Distribution(self.treasury, post_balance)
    log TotalDistribution(balance)

### EXTERNAL FUNCTIONS
@external
def set_fee_recipients(recipients: DynArray[address, 10], points: DynArray[uint256, 10]):
    assert msg.sender == self.owner, "!OWNER"
    assert len(recipients) == len(points), "!MISMATCH"
    self.total_points = 0
    self.recipients = recipients
    for i: uint256 in range(10):
        if i >= len(recipients):
            break
        self.points[recipients[i]] = points[i]
        self.total_points += points[i]

@external
def add_recipient(recipient: address, points: uint256):
    assert msg.sender == self.owner, "!OWNER"
    assert self.points[recipient] == 0, "!DUPLICATE"
    self.points[recipient] = points
    self.total_points += points
    self.recipients.append(recipient)
    log RecipientAdded(recipient, points)

@external
def adjust_points_for_recipient(recipient: address, points: uint256):
    # remove pools by setting points to 0
    assert msg.sender == self.owner, "!OWNER"
    self.total_points -= self.points[recipient]
    self.total_points += points
    self.points[recipient] = points
    log RecipientModified(recipient, points)

event Foo:
    bar: uint256

@external
def pull_rewards(amount: uint256, token: address):
    assert msg.sender == self.source, "!SOURCE"
    assert self.token.address == token, "!TOKEN"
    extcall self.token.transferFrom(msg.sender, self, amount)
    self.distribute_accumulated_rewards()

@external
def distribute():
    assert msg.sender == self.owner, "!OWNER"
    self.distribute_accumulated_rewards()
