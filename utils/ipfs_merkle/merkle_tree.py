from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import List, Sequence


try:
    from eth_hash.auto import keccak  # type: ignore
except ImportError:  # pragma: no cover - fallback path
    try:
        import sha3  # type: ignore
    except ImportError as exc:  # pragma: no cover - fallback path
        raise ImportError(
            "Install eth-hash or pysha3 to compute Keccak-256 hashes"
        ) from exc

    def keccak(data: bytes) -> bytes:  # type: ignore
        digest = sha3.keccak_256()
        digest.update(data)
        return digest.digest()


@dataclass(frozen=True)
class MerkleProof:
    index: int
    leaf: str
    proof: List[str]


class MerkleTree:
    def __init__(
        self,
        leaves: Sequence[bytes],
        *,
        hash_leaves: bool = True,
        sort_pairs: bool = True,
    ) -> None:
        if not leaves:
            raise ValueError("Merkle tree requires at least one leaf")
        self.sort_pairs = sort_pairs
        self.leaves = [keccak(leaf) if hash_leaves else leaf for leaf in leaves]
        self.layers: List[List[bytes]] = []
        self._build_layers()

    def _build_layers(self) -> None:
        current_layer = self.leaves
        self.layers = [current_layer]
        while len(current_layer) > 1:
            next_layer: List[bytes] = []
            for i in range(0, len(current_layer), 2):
                left = current_layer[i]
                right = current_layer[i + 1] if i + 1 < len(current_layer) else left
                combined = self._hash_pair(left, right)
                next_layer.append(combined)
            current_layer = next_layer
            self.layers.append(current_layer)

    def _hash_pair(self, left: bytes, right: bytes) -> bytes:
        if self.sort_pairs and right < left:
            left, right = right, left
        return keccak(left + right)

    @property
    def root(self) -> bytes:
        return self.layers[-1][0]

    def get_proof(self, index: int) -> List[bytes]:
        if index < 0 or index >= len(self.leaves):
            raise IndexError("Leaf index out of range")
        proof: List[bytes] = []
        for layer in self.layers[:-1]:
            layer_length = len(layer)
            is_right_node = index % 2
            pair_index = index - 1 if is_right_node else index + 1
            if pair_index < layer_length:
                proof.append(layer[pair_index])
            index //= 2
        return proof

    def build_hex_proof(self, index: int) -> MerkleProof:
        proof_bytes = self.get_proof(index)
        return MerkleProof(
            index=index,
            leaf=self.leaves[index].hex(),
            proof=[node.hex() for node in proof_bytes],
        )

    def build_all_hex_proofs(self) -> List[MerkleProof]:
        return [self.build_hex_proof(i) for i in range(len(self.leaves))]


def _manifest_leaf(entry: dict) -> bytes:
    payload = f"{entry['name']}:{entry['cid']}".encode("utf-8")
    return payload


def build_merkle_tree_from_manifest(manifest: Path) -> MerkleTree:
    manifest_data = json.loads(manifest.read_text())
    leaves = [_manifest_leaf(entry) for entry in manifest_data.get("files", [])]
    if not leaves:
        raise ValueError("Manifest does not contain any files")
    return MerkleTree(leaves, hash_leaves=True, sort_pairs=True)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a Merkle tree from an IPFS manifest")
    parser.add_argument("manifest", type=Path, help="Path to manifest JSON produced by ipfs_uploader")
    parser.add_argument("--out", type=Path, default=Path("merkle_proofs.json"), help="Output path for proofs")
    return parser.parse_args()


def _run_cli() -> None:
    args = _parse_args()
    tree = build_merkle_tree_from_manifest(args.manifest)
    output = {
        "root": "0x" + tree.root.hex(),
        "proofs": [asdict(proof) for proof in tree.build_all_hex_proofs()],
    }
    args.out.write_text(json.dumps(output, indent=2))
    print(f"Merkle root: 0x{tree.root.hex()}")
    print(f"Proofs written to {args.out}")


if __name__ == "__main__":
    _run_cli()
