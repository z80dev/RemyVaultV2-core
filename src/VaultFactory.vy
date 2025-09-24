# pragma version ^0.4.3

from ethereum.ercs import IERC721

blueprint_address: public(immutable(address))

interface Metadata:
    def name() -> String[25]: view
    def symbol() -> String[5]: view

@deploy
def __init__(_blueprint_address: address):
    blueprint_address = _blueprint_address

@external
def create_vault(nft: address) -> address:
    """
    Deploys a new RemyVaultERC20 contract using the blueprint address provided at deployment.
    The caller is set as the owner of the new vault.
    """
    assert nft != empty(address), "Invalid NFT address"

    nft_name: String[25] = staticcall Metadata(nft).name()
    nft_symbol: String[5] = staticcall Metadata(blueprint_address).symbol()

    new_vault: address = create_from_blueprint(
        blueprint_address,
        nft_name,
        nft_symbol,
        nft,
        salt=convert(nft, bytes32)
    )

    return new_vault
