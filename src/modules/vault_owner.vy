# pragma version ^0.4.3

from ..interfaces import LegacyRemyVault as RemyVault
from ..interfaces import OldRouter

from snekmate.auth import ownable

vault: public(RemyVault)
legacy_router: public(OldRouter)
vault_address: public(address)
weth: public(address)
v3router_address: public(address)
erc4626_address: public(address)
uses: ownable

@deploy
def __init__(old_router: address):
    self._sync_legacy_router(old_router)

@internal
def _sync_legacy_router(old_router: address):
    router: OldRouter = OldRouter(old_router)

    vault_addr: address = staticcall router.vault_address()
    self.vault = RemyVault(vault_addr)
    self.vault_address = vault_addr

    self.weth = staticcall router.weth()
    self.v3router_address = staticcall router.v3router_address()
    self.erc4626_address = staticcall router.erc4626_address()

    self.legacy_router = router

@external
def transfer_vault_ownership(new_owner: address):
    ownable._check_owner()
    extcall self.vault.set_fee_exempt(new_owner, True)
    extcall self.vault.transfer_owner(new_owner)


@internal
def _enable_vault():
    extcall self.vault.set_active(True)

@internal
def _disable_vault():
    extcall self.vault.set_active(False)

@view
@external
def legacy_vault_addresses() -> (address, address):
    erc721_address: address = staticcall self.vault.erc721()
    erc20_address: address = staticcall self.vault.erc20()

    return erc721_address, erc20_address
