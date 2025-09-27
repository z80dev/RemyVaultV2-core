# IPFS & Merkle Utilities

Tools to upload local assets to IPFS and generate Merkle proofs that can be re-created inside Solidity for on-chain verification.

## Layout
- `ipfs_uploader.py` – CLI and helper class for uploading files or directories via Pinata or a local IPFS node.
- `merkle_tree.py` – Merkle tree helper with a CLI to emit a root and per-file proofs from the upload manifest.
- `requirements.txt` – Minimal Python dependencies (installed with `uv`).
- `../images/` – Drop the image assets you want to process here (kept empty with `.gitkeep`).

## Installation
```bash
uv pip install -r utils/ipfs_merkle/requirements.txt
```

## Uploading Images
```bash
uv run python utils/ipfs_merkle/ipfs_uploader.py utils/images --mode pinata --manifest-out utils/ipfs_merkle/out/ipfs_manifest.json
```

The uploader reads credentials from environment variables:
- `PINATA_JWT` (preferred) **or** both `PINATA_API_KEY` and `PINATA_SECRET_API_KEY`
- `IPFS_MODE`, `IPFS_API_URL`, `IPFS_CID_VERSION`, `IPFS_MANIFEST_OUT` can override CLI defaults

For a self-hosted node:
```bash
uv run python utils/ipfs_merkle/ipfs_uploader.py utils/images --mode local --ipfs-api-url http://127.0.0.1:5001/api/v0/add
```

The script prints each upload result and writes a manifest JSON containing the CID, filename, and service used.

## Building Merkle Proofs
Use the manifest to derive proofs that match Solidity's `keccak256(abi.encodePacked(name, ":", cid))` leaf convention.
```bash
uv run python utils/ipfs_merkle/merkle_tree.py utils/ipfs_merkle/out/ipfs_manifest.json --out utils/ipfs_merkle/out/merkle_proofs.json
```

The output file includes the Merkle root and per-file proofs. Store the root in your contract and verify proofs with the supplied hashes.

## Solidity Verification Snippet
```solidity
function _leaf(string memory name, string memory cid) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(name, ":", cid));
}

function verify(bytes32 root, bytes32[] memory proof, bytes32 leaf) internal pure returns (bool) {
    return MerkleProof.verify(proof, root, leaf);
}
```

Adjust the leaf encoding if you need a different schema (e.g., including token IDs). Keep the Python and Solidity hashing logic aligned.
