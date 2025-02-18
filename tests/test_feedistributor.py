#!/usr/bin/env python3
import pytest
from ape.api.address import Address

@pytest.fixture
def deployer(accounts):
    return accounts[0]

@pytest.fixture
def mock_token(project, deployer):
    return project.MockERC20.deploy(sender=deployer)

@pytest.fixture
def fee_distributor(project, deployer, mock_token):
    return project.FeeDistributor.deploy(mock_token, deployer, deployer, sender=deployer)

def test_returns_when_no_funds(deployer, fee_distributor):
    fee_distributor.distribute(sender=deployer)

def test_sends_to_deployer_when_no_recipients(deployer, fee_distributor, mock_token):
    amount = 1000 * 10 ** 18

    # mint mock tokens
    mock_token.mint(amount, sender=deployer)
    mock_token.approve(fee_distributor, amount, sender=deployer)

    # distribute mock tokens
    tx = fee_distributor.pull_rewards(amount, mock_token, sender=deployer)

    # check expected distribution
    assert mock_token.balanceOf(deployer) == amount
    assert fee_distributor.Distribution(deployer, amount) in tx.events
    assert fee_distributor.TotalDistribution(amount) in tx.events

def test_splits_between_recipients(project, deployer, fee_distributor, mock_token, accounts):
    amount = 1000 * 10 ** 18

    # mint mock tokens
    mock_token.mint(amount, sender=deployer)
    mock_token.approve(fee_distributor, amount, sender=deployer)

    recipients = [project.FeeRecipient.deploy(sender=deployer) for _ in range(10)]
    points = [10] * 10

    fee_distributor.set_fee_recipients(recipients, points, sender=deployer)

    # distribute mock tokens
    tx = fee_distributor.pull_rewards(amount, mock_token, sender=deployer)

    # check expected distribution
    assert mock_token.balanceOf(deployer) == 0
    assert fee_distributor.Distribution(deployer, 0) in tx.events
    assert fee_distributor.TotalDistribution(amount) in tx.events
