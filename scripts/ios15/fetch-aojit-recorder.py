#!/usr/bin/env python3
"""Download only the pinned recorder artifact. No credentials on storage requests."""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[2]


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def main(output):
    bundle = json.loads((ROOT / 'deps/aot/images.lock.json').read_text())['recorder_bundle']
    if bundle['repository'] != 'JudeGor1129/aojit-recorder':
        raise ValueError('unexpected recorder repository')
    artifact = int(bundle['image_artifact_id'])
    size, sha = bundle['image_zip_bytes'], bundle['image_zip_sha256']
    token = os.environ.get('AOJIT_ARTIFACT_TOKEN')
    if not token:
        raise ValueError('configure AOJIT_ARTIFACT_TOKEN with Actions: read on JudeGor1129/aojit-recorder')
    base = f'https://api.github.com/repos/JudeGor1129/aojit-recorder/actions/artifacts/{artifact}'
    opener = build_opener(NoRedirect)
    headers = {'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + token,
               'User-Agent': 'Minis-AOJIT-CI', 'X-GitHub-Api-Version': '2022-11-28'}
    with opener.open(Request(base, headers=headers), timeout=35) as response:
        meta = json.load(response)
    source = meta.get('workflow_run') or {}
    if (meta.get('id') != artifact or meta.get('expired') is not False
            or meta.get('name') != 'aojit-images-1.15-run16'
            or meta.get('size_in_bytes') != size or meta.get('digest') != 'sha256:' + sha
            or source.get('id') != bundle['run_id'] or source.get('head_sha') != bundle['commit']):
        raise ValueError('recorder artifact metadata mismatches the lock or artifact expired')
    if output is None:
        print(f'PASS: artifact {artifact} metadata, access and origin match the lock (ZIP not downloaded)')
        return
    try:
        response = opener.open(Request(base + '/zip', headers=headers), timeout=35)
    except HTTPError as exc:
        if exc.code != 302:
            raise
        location = exc.headers.get('Location', '')
        url = urlsplit(location)
        if (url.scheme != 'https' or url.username or url.password or url.port not in (None, 443)
                or not (url.hostname or '').endswith(('.blob.core.windows.net', '.githubusercontent.com'))):
            raise ValueError('unexpected artifact storage redirect') from None
        response = opener.open(Request(location, headers={'User-Agent': 'Minis-AOJIT-CI'}), timeout=180)
    tmp = None
    try:
        with response, tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as file:
            tmp = Path(file.name)
            digest = hashlib.sha256()
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > size:
                    raise ValueError('archive exceeds locked size')
                digest.update(chunk)
                file.write(chunk)
        if total != size or digest.hexdigest() != sha:
            raise ValueError('recorder archive SHA-256 or size mismatch')
        tmp.replace(output)
        print(f'PASS: recorder artifact {artifact}: {total} bytes, SHA-256 {sha}')
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--output', type=Path)
    mode.add_argument('--check-metadata', action='store_true')
    cli = parser.parse_args()
    try:
        main(cli.output)
    except HTTPError as exc:
        raise SystemExit(f'ERROR: HTTP {exc.code} fetching recorder artifact; check expiry and recorder Actions: read permission') from None
    except ValueError as exc:
        raise SystemExit(f'ERROR: {exc}') from None
    except (OSError, KeyError) as exc:
        raise SystemExit(f'ERROR: {type(exc).__name__}: recorder artifact fetch failed') from None
