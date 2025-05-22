# pragma version ^0.4.0
# Contract that handles compound actions on behalf of users
# Covers the following use cases:
# - Liquidity Management
# - Wrapping/Unwrapping for staking reasons
# - Batch actions

from ethereum.ercs import IERC20 as ERC20
from ethereum.ercs import IERC721 as ERC721
from ethereum.ercs import IERC4626 as ERC4626

interface RemyVault:
    def mint(tokenId: uint256, recipient: address): nonpayable
    def mint_batch(tokenIds: DynArray[uint256, 100], recipient: address, force_fee: bool) -> uint256: nonpayable
    def redeem(tokenId: uint256, recipient: address): nonpayable
    def redeem_batch(tokenIds: DynArray[uint256, 100], recipient: address, force_fee: bool) -> uint256: nonpayable
    def onERC721Received(operator: address, _from: address, tokenId: uint256, data: Bytes[256]) -> bytes4: nonpayable
    def transfer_owner(new_owner: address): nonpayable
    def set_fees(fees: uint256[2]): nonpayable
    def set_active(active: bool): nonpayable
    def set_fee_exempt(exempt: address, is_exempt: bool): nonpayable
    def set_rbtoken_fee_receiver(receiver: address): nonpayable
    def erc20() -> address: view
    def erc721() -> address: view
    def active() -> bool: view
    def owner() -> address: view
    def mint_fee() -> uint256: view
    def redeem_fee() -> uint256: view
    def rbtoken_fee_receiver() -> address: view
    def fee_exempt(arg0: address) -> bool: view
    def quote_redeem(count: uint256, force_fee: bool) -> uint256: view
    def quote_mint(count: uint256, force_fee: bool) -> uint256: view
    def quote_redeem_fee(recipient: address, num_tokens: uint256) -> uint256: view
    def quote_mint_fee(recipient: address, num_tokens: uint256) -> uint256: view
    def charge_fee(amt: uint256): nonpayable

interface DN404:
    def setSkipNFT(skip: bool) -> bool: nonpayable

interface WETH9:
    def deposit(): payable
    def withdraw(amount: uint256): nonpayable
    def balanceOf(account: address) -> uint256: view

struct ExactInputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    amountIn: uint256
    amountOutMinimum: uint256
    sqrtPriceLimitX96: uint160

struct ExactOutputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    amountOut: uint256
    amountInMaximum: uint256
    sqrtPriceLimitX96: uint160

# v3 router interface
interface SwapRouter:
    def exactInputSingle(params: ExactInputSingleParams) -> uint256: payable
    def exactOutputSingle(params: ExactOutputSingleParams) -> uint256: payable

# going to store some addresses in storage to avoid passing them around
owner: public(address)
vault_address: public(address)
router_address: public(address)
weth: public(address)
v3router_address: public(address)
erc4626_address: public(address)
erc721_address: public(address)
erc20_address: public(address)

interface OldRouter:
    def vault_address() -> address: view
    def weth() -> address: view
    def v3router_address() -> address: view
    def erc4626_address() -> address: view

@deploy
def __init__(old_router: address):
    self.owner = msg.sender
    self.vault_address = staticcall OldRouter(old_router).vault_address()
    self.weth = staticcall OldRouter(old_router).weth()
    self.v3router_address = staticcall OldRouter(old_router).v3router_address()
    self.erc4626_address = staticcall OldRouter(old_router).erc4626_address()
    self.erc721_address = staticcall RemyVault(self.vault_address).erc721()
    self.erc20_address = staticcall RemyVault(self.vault_address).erc20()

    # approve vault for all erc721 transfers
    extcall ERC721(self.erc721_address).setApprovalForAll(self.vault_address, True)

@external
def stake_inventory(recipient: address, token_ids: DynArray[uint256, 100]):
    """
    Stakes an NFT in the vault
    """
    vault: RemyVault = RemyVault(self.vault_address)
    extcall vault.set_active(True)
    nft: ERC721 = ERC721(self.erc721_address)
    nft_token: ERC20 = ERC20(self.erc20_address)
    erc4626: ERC4626 = ERC4626(self.erc4626_address)
    for token_id: uint256 in token_ids:
        extcall nft.transferFrom(msg.sender, self, token_id)
    extcall DN404(nft_token.address).setSkipNFT(True)
    minted: uint256 = extcall vault.mint_batch(token_ids, self, False)
    extcall nft_token.approve(self.erc4626_address, minted)
    extcall erc4626.deposit(minted, recipient)
    extcall vault.set_active(False)

@external
def unstake_inventory(recipient: address, token_ids: DynArray[uint256, 100]):
    """
    Unstakes an NFT from the vault
    """
    vault: RemyVault = RemyVault(self.vault_address)
    extcall vault.set_active(True)
    nft: ERC721 = ERC721(self.erc721_address)
    nft_token: ERC20 = ERC20(self.erc20_address)
    erc4626: ERC4626 = ERC4626(self.erc4626_address)
    start_bal: uint256 = staticcall ERC20(self.erc4626_address).balanceOf(self)
    tokens_required: uint256 = staticcall vault.quote_redeem(len(token_ids), False)
    shares_required: uint256 = staticcall erc4626.convertToShares(tokens_required) + 1
    extcall ERC20(self.erc4626_address).transferFrom(msg.sender, self, shares_required)
    extcall erc4626.withdraw(tokens_required, self, self)
    extcall nft_token.approve(self.vault_address, tokens_required)
    extcall vault.redeem_batch(token_ids, recipient, False)
    if staticcall ERC20(self.erc4626_address).balanceOf(self) > start_bal:
        extcall ERC20(self.erc4626_address).transfer(recipient, staticcall ERC20(self.erc4626_address).balanceOf(self) - start_bal)
    extcall vault.set_active(False)

@internal
def wrap_eth(amount: uint256):
    """
    Wraps ETH into WETH
    """
    extcall WETH9(self.weth).deposit(value=amount)

@internal
def unwrap_eth(amount: uint256):
    """
    Unwraps WETH into ETH
    """
    extcall WETH9(self.weth).withdraw(amount)

@internal
def swap_erc20_for_weth(amountIn: uint256) -> uint256:
    """
    Swaps ERC20 tokens for WETH
    """
    router: SwapRouter = SwapRouter(self.v3router_address)
    token: ERC20 = ERC20(self.erc20_address)
    params: ExactInputSingleParams = ExactInputSingleParams(
        tokenIn = self.erc20_address,
        tokenOut = self.weth,
        fee = 3000,
        recipient = self,
        amountIn = amountIn,
        amountOutMinimum = 0,
        sqrtPriceLimitX96 = 0
    )
    extcall token.approve(self.v3router_address, amountIn)
    return_val: uint256 = extcall router.exactInputSingle(params)
    log ERC20SwappedForWETH(swapper=msg.sender, amountIn=amountIn, amountOut=return_val)
    return return_val

event ERC20SwappedForWETH:
    swapper: indexed(address)
    amountIn: uint256
    amountOut: uint256

event WETHSwappedForERC20:
    swapper: indexed(address)
    amountIn: uint256
    amountOut: uint256

@payable
@internal
def swap_weth_for_erc20(amountOut: uint256) -> uint256:
    """
    Swaps WETH for ERC20 tokens
    """
    router: SwapRouter = SwapRouter(self.v3router_address)
    token: ERC20 = ERC20(self.erc20_address)
    params: ExactOutputSingleParams = ExactOutputSingleParams(
        tokenIn = self.weth,
        tokenOut = self.erc20_address,
        fee = 3000,
        recipient = self,
        amountOut = amountOut,
        amountInMaximum = msg.value,
        sqrtPriceLimitX96 = 0
    )
    extcall ERC20(self.weth).approve(self.v3router_address, msg.value)
    return_val: uint256 = extcall router.exactOutputSingle(params)
    log WETHSwappedForERC20(swapper=msg.sender, amountIn=msg.value, amountOut=return_val)
    return return_val

@payable
@external
def swap_eth_for_nft_v3(tokenIds: DynArray[uint256, 100], recipient: address):
    """
    Swaps ETH for an NFT using the v3 router
    """
    router: SwapRouter = SwapRouter(self.v3router_address)
    vault: RemyVault = RemyVault(self.vault_address)
    extcall vault.set_active(True)
    token: ERC20 = ERC20(self.erc20_address)
    min_out: uint256 = staticcall vault.quote_redeem(len(tokenIds), True)
    extcall WETH9(self.weth).deposit(value=msg.value)
    self.swap_weth_for_erc20(min_out)
    assert self.vault_address != empty(address), "vault address not set"
    extcall token.approve(self.vault_address, min_out)
    extcall vault.redeem_batch(tokenIds, recipient, True)
    extcall vault.set_active(False)

@external
def swap_nft_for_eth_v3(tokenIds: DynArray[uint256, 100], min_out: uint256, recipient: address):
    """
    Swaps an NFT for ETH using the v3 router
    """
    router: SwapRouter = SwapRouter(self.v3router_address)
    vault: RemyVault = RemyVault(self.vault_address)
    extcall vault.set_active(True)
    token: ERC20 = ERC20(self.erc20_address)
    nft: ERC721 = ERC721(self.erc721_address)
    for token_id: uint256 in tokenIds:
        extcall nft.transferFrom(msg.sender, self, token_id)
    extcall DN404(token.address).setSkipNFT(True)
    minted_amt: uint256 = extcall vault.mint_batch(tokenIds, self, True)
    extcall token.approve(self.v3router_address, staticcall token.balanceOf(self))
    weth_balance_before: uint256 = staticcall WETH9(self.weth).balanceOf(self)
    params: ExactInputSingleParams = ExactInputSingleParams(
        tokenIn = self.erc20_address,
        tokenOut = self.weth,
        fee = 3000,
        recipient = self,
        amountIn = minted_amt,
        amountOutMinimum = 0,
        sqrtPriceLimitX96 = 0
    )
    extcall router.exactInputSingle(params)
    weth_balance_after: uint256 = staticcall WETH9(self.weth).balanceOf(self)
    extcall WETH9(self.weth).withdraw(weth_balance_after - weth_balance_before)
    send(recipient, weth_balance_after - weth_balance_before)
    extcall vault.set_active(False)

event NFTsSwappedForNFTs:
    swapper: indexed(address)
    nfts_in_count: uint256
    nfts_out_count: uint256
    fee: uint256
    proceeds: uint256

event MintFeeCharged:
    swapper: indexed(address)
    recipient: indexed(address)
    fee: uint256

event RedeemFeeCharged:
    swapper: indexed(address)
    recipient: indexed(address)
    fee: uint256

event SaleProceeds:
    swapper: indexed(address)
    proceeds: uint256

event WethRefunded:
    swapper: indexed(address)
    proceeds: uint256

@view
@external
def quote_swap_in_tokens(tokenIds_in: DynArray[uint256, 100], tokenIds_out: DynArray[uint256, 100]) -> uint256:
    """
    Quotes the amount of tokens required to be bought to swap NFTs for NFTs
    Tokens are required to pay for the redeem fee on swaps
    """
    if len(tokenIds_in) > len(tokenIds_out):
        return 0
    vault: RemyVault = RemyVault(self.vault_address)
    total_tokens_required: uint256 = 0
    mint_fee: uint256 = 0
    num_swaps: uint256 = min(len(tokenIds_in), len(tokenIds_out))
    num_bought: uint256 = len(tokenIds_out) - num_swaps
    num_sold: uint256 = len(tokenIds_in) - num_swaps
    if num_bought > 0:
        mint_fee = staticcall vault.quote_mint_fee(msg.sender, num_bought)
    total_tokens_required = staticcall vault.quote_redeem(len(tokenIds_out), True)
    total_tokens_minted: uint256 = staticcall vault.quote_mint(len(tokenIds_in), False)
    if mint_fee > 0:
        total_tokens_required += mint_fee
    if total_tokens_minted < total_tokens_required:
        return total_tokens_required - total_tokens_minted
    return 0

# function that takes in a list of tokenIds being bought, a list of tokenIds being sold, and the recipient
# the contract should calculate any eth payment required and charge the user
# if instead there are more in than out, the contract should calculate the amount of eth to send back
# steps:
# 1. transfer the NFTs to the contract
# 2. mint token with the vault
# 3. calculate the amount of tokens required to redeem the NFTs
# 4a. if the user has enough tokens, go to step 5
# 4b. if the user does not have enough tokens, swap eth for the required amount of tokens
# 5. approve the vault to spend the tokens
# 6. redeem the desired NFTs with the tokens
# 7. transfer the NFTs to the recipient
# 8. if there are tokens left over, sell them for eth and send the eth to the user
# nfts swapped for nfts dont have to pay the mint fee, everything gets charged the redeem fee
@payable
@external
def swap(tokenIds_in: DynArray[uint256, 100], tokenIds_out: DynArray[uint256, 100], recipient: address):
    """
    Swaps NFTs for NFTs by redeeming the NFTs for 1000 ERC20 tokens and swapping them for the target NFT
    """
    # get the vault, nft, and token contracts
    vault: RemyVault = RemyVault(self.vault_address)
    extcall vault.set_active(True)
    nft: ERC721 = ERC721(self.erc721_address)
    token: ERC20 = ERC20(self.erc20_address)

    # initialize state we will use throughout
    total_tokens_to_sell: uint256 = 0 # erc20 tokens not needed for redeem
    total_tokens_to_buy: uint256 = 0

    # don't blindly trust user balances
    # in case of reentrancy could be an issue
    # instead we check balance before and after batch_mint
    bal_before: uint256 = staticcall token.balanceOf(self)
    bal_after: uint256 = 0

    # transfer the NFTs to the contract
    for token_id: uint256 in tokenIds_in:
        extcall nft.transferFrom(msg.sender, self, token_id)

    # calculate how many are nft-nft swaps
    num_swaps: uint256 = min(len(tokenIds_in), len(tokenIds_out))

    # num_bought is the number of nfts that the user is buying
    # beyond the nft-nft swaps and should be charged the full fee
    num_bought: uint256 = len(tokenIds_out)
    num_bought -= num_swaps

    # num_sold is the number of nfts that the user is selling
    # beyond the nft-nft swaps and should be charged the full fee
    num_sold: uint256 = len(tokenIds_in)
    num_sold -= num_swaps

    extcall DN404(token.address).setSkipNFT(True)
    amt_minted: uint256 = 0

    if len(tokenIds_in) > 0:
        amt_minted = extcall vault.mint_batch(tokenIds_in, self, False)

    bal_after = staticcall token.balanceOf(self)

    assert bal_after - bal_before == amt_minted, "minted amount does not match"

    # TODO: this is a bug, we don't mint the ERC20 on *buys*, only on sells, buys only involve redeeming
    # charge fees on num_bought nfts, this is the only time we charge mint fees
    # this avoids bvpassing the mint fee through this swap method
    mint_fee: uint256 = 0
    if num_sold > 0:
        mint_fee = staticcall vault.quote_mint_fee(recipient, num_sold)

    total_tokens_required: uint256 = staticcall vault.quote_redeem(len(tokenIds_out), True)
    if mint_fee > 0:
        total_tokens_required += mint_fee
        log MintFeeCharged(swapper=msg.sender, recipient=recipient, fee=mint_fee)

    if amt_minted < total_tokens_required:
        total_tokens_to_buy = total_tokens_required - amt_minted

    if total_tokens_to_buy > 0:
        weth_balance_before: uint256 = staticcall WETH9(self.weth).balanceOf(self)
        extcall WETH9(self.weth).deposit(value=msg.value)
        self.swap_weth_for_erc20(total_tokens_to_buy)
        # charge mint fee we calculated earlier
        if mint_fee > 0:
            extcall token.approve(self.vault_address, staticcall token.balanceOf(self))
            extcall vault.charge_fee(mint_fee)
        weth_balance_after: uint256 = staticcall WETH9(self.weth).balanceOf(self)
        # if we have leftover weth, send it back
        # it was provided as eth so we unwrap it
        if weth_balance_after > weth_balance_before:
            diff: uint256 = weth_balance_after - weth_balance_before
            extcall WETH9(self.weth).withdraw(diff)
            send(msg.sender, diff)
            log WethRefunded(swapper=msg.sender, proceeds=diff)
    extcall token.approve(self.vault_address, staticcall token.balanceOf(self))
    amt_redeemed: uint256 = extcall vault.redeem_batch(tokenIds_out, recipient, True)
    amt_leftover: uint256 = 0
    if amt_minted > amt_redeemed:
        amt_leftover = amt_minted - amt_redeemed

    # return leftover erc20 tokens to the user as eth
    if amt_leftover > 0:
        extcall token.approve(self.v3router_address, amt_leftover)
        swap_amt: uint256 = self.swap_erc20_for_weth(amt_leftover)
        extcall WETH9(self.weth).withdraw(swap_amt)
        send(msg.sender, swap_amt)
        log SaleProceeds(swapper=msg.sender, proceeds=swap_amt)

    log NFTsSwappedForNFTs(swapper=recipient, nfts_in_count=len(tokenIds_in), nfts_out_count=len(tokenIds_out), fee=mint_fee, proceeds=amt_leftover)
    extcall vault.set_active(False)

@external
def transfer_owner(new_owner: address):
    assert msg.sender == self.owner
    self.owner = new_owner

@external
def transfer_vault_ownership(new_owner: address):
    assert msg.sender == self.owner
    extcall RemyVault(self.vault_address).transfer_owner(new_owner)

@payable
@external
def __default__():
    pass
