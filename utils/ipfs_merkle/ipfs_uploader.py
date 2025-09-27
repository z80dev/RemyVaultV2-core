from __future__ import annotations

import argparse
import dataclasses
import json
import os
from pathlib import Path
from typing import Iterable, Optional

import requests


PINATA_BASE_URL = "https://api.pinata.cloud"
PINATA_UPLOAD_ENDPOINT = f"{PINATA_BASE_URL}/pinning/pinFileToIPFS"
LOCAL_IPFS_API = "http://127.0.0.1:5001/api/v0/add"


@dataclasses.dataclass(slots=True)
class UploadResult:
    """Capture information returned after uploading a file to IPFS."""

    cid: str
    name: str
    size: int
    uri: str
    service: str


class IPFSUploader:
    """Utility class that supports Pinata or a local IPFS HTTP API."""

    def __init__(
        self,
        *,
        mode: str = "pinata",
        pinata_jwt: Optional[str] = None,
        pinata_api_key: Optional[str] = None,
        pinata_secret_api_key: Optional[str] = None,
        ipfs_api_url: str = LOCAL_IPFS_API,
        cid_version: int = 1,
        timeout: int = 120,
    ) -> None:
        if mode not in {"pinata", "local"}:
            raise ValueError("mode must be 'pinata' or 'local'")
        self.mode = mode
        self.pinata_jwt = pinata_jwt or os.getenv("PINATA_JWT")
        self.pinata_api_key = pinata_api_key or os.getenv("PINATA_API_KEY")
        self.pinata_secret_api_key = (
            pinata_secret_api_key or os.getenv("PINATA_SECRET_API_KEY")
        )
        self.ipfs_api_url = ipfs_api_url
        self.cid_version = cid_version
        self.timeout = timeout
        if self.mode == "pinata" and not self._has_pinata_credentials:
            raise ValueError(
                "Pinata mode selected but no credentials provided."
                " Set PINATA_JWT or both PINATA_API_KEY and PINATA_SECRET_API_KEY."
            )

    @property
    def _has_pinata_credentials(self) -> bool:
        if self.pinata_jwt:
            return True
        return bool(self.pinata_api_key and self.pinata_secret_api_key)

    def upload_path(self, target: Path) -> UploadResult:
        if not target.exists():
            raise FileNotFoundError(target)
        if target.is_dir():
            raise IsADirectoryError(target)
        if self.mode == "pinata":
            return self._upload_via_pinata(target)
        return self._upload_via_local_node(target)

    def upload_directory(self, directory: Path) -> list[UploadResult]:
        if not directory.exists() or not directory.is_dir():
            raise NotADirectoryError(directory)
        results: list[UploadResult] = []
        for file_path in sorted(directory.iterdir()):
            if file_path.is_file():
                results.append(self.upload_path(file_path))
        return results

    def _upload_via_pinata(self, target: Path) -> UploadResult:
        headers = {}
        if self.pinata_jwt:
            headers["Authorization"] = f"Bearer {self.pinata_jwt}"
        else:
            headers["pinata_api_key"] = self.pinata_api_key  # type: ignore[assignment]
            headers["pinata_secret_api_key"] = (
                self.pinata_secret_api_key  # type: ignore[assignment]
            )
        metadata = json.dumps({"name": target.name})
        options = json.dumps({"cidVersion": self.cid_version})
        with target.open("rb") as handle:
            files = {"file": (target.name, handle)}
            response = requests.post(
                PINATA_UPLOAD_ENDPOINT,
                files=files,
                data={"pinataMetadata": metadata, "pinataOptions": options},
                headers=headers,
                timeout=self.timeout,
            )
        if response.status_code != 200:
            raise RuntimeError(
                f"Pinata upload failed for {target.name}: {response.status_code} {response.text}"
            )
        payload = response.json()
        cid = payload["IpfsHash"]
        size = int(payload.get("PinSize", target.stat().st_size))
        uri = f"ipfs://{cid}"
        return UploadResult(
            cid=cid,
            name=target.name,
            size=size,
            uri=uri,
            service="pinata",
        )

    def _upload_via_local_node(self, target: Path) -> UploadResult:
        params = {"cid-version": str(self.cid_version), "pin": "true"}
        with target.open("rb") as handle:
            files = {"file": (target.name, handle)}
            response = requests.post(
                self.ipfs_api_url,
                params=params,
                files=files,
                timeout=self.timeout,
            )
        if response.status_code != 200:
            raise RuntimeError(
                f"Local IPFS upload failed for {target.name}: {response.status_code} {response.text}"
            )
        payload = response.json()
        cid = payload["Hash"]
        uri = f"ipfs://{cid}"
        size = target.stat().st_size
        return UploadResult(
            cid=cid,
            name=target.name,
            size=size,
            uri=uri,
            service="local",
        )


def _iter_image_files(paths: Iterable[Path]) -> Iterable[Path]:
    for path in paths:
        if path.is_dir():
            for candidate in sorted(path.rglob("*")):
                if candidate.is_file():
                    yield candidate
        elif path.is_file():
            yield path


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload a collection of files to IPFS via Pinata or a local node",
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="File or directory paths to upload",
    )
    parser.add_argument(
        "--mode",
        choices=["pinata", "local"],
        default=os.getenv("IPFS_MODE", "pinata"),
        help="Uploader backend (default: pinata)",
    )
    parser.add_argument(
        "--ipfs-api-url",
        default=os.getenv("IPFS_API_URL", LOCAL_IPFS_API),
        help="HTTP API endpoint when using a local IPFS node",
    )
    parser.add_argument(
        "--cid-version",
        type=int,
        default=int(os.getenv("IPFS_CID_VERSION", "1")),
        help="CID version to request from the node",
    )
    parser.add_argument(
        "--manifest-out",
        type=Path,
        default=Path(os.getenv("IPFS_MANIFEST_OUT", "ipfs_manifest.json")),
        help="Where to write the manifest summarising uploads",
    )
    return parser.parse_args()


def _run_cli() -> None:
    args = _parse_args()
    uploader = IPFSUploader(
        mode=args.mode,
        ipfs_api_url=args.ipfs_api_url,
        cid_version=args.cid_version,
    )
    all_results: list[UploadResult] = []
    for path in _iter_image_files(args.paths):
        result = uploader.upload_path(path)
        print(json.dumps(dataclasses.asdict(result)))
        all_results.append(result)
    manifest = {
        "service": uploader.mode,
        "cidVersion": uploader.cid_version,
        "files": [dataclasses.asdict(result) for result in all_results],
    }
    manifest_path = args.manifest_out.resolve()
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Manifest written to {manifest_path}")


if __name__ == "__main__":
    _run_cli()
