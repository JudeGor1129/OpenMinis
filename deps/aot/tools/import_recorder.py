#!/usr/bin/env python3
"""Import 25 allowlisted assembly sources from pinned AOJIT recorder run16.

The archive and all 28 manifest headers are verified. Only 25 catalog images
are installed; excluded modules and preassembled .o files are never linked.
Existing images are replaced only when their SHA matches the locked prior
run7 input. No guest code is executed.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path

from image_info import info

CHUNK = 1024 * 1024


def hash_stream(source, expected_size=None, output=None):
    digest = hashlib.sha256()
    size = 0
    while True:
        data = source.read(CHUNK if expected_size is None else min(CHUNK, expected_size - size))
        if not data:
            break
        size += len(data)
        if expected_size is not None and size > expected_size:
            raise ValueError('input exceeds locked size')
        digest.update(data)
        if output is not None:
            output.write(data)
    if expected_size is not None:
        if size != expected_size:
            raise ValueError(f'truncated input: expected {expected_size}, got {size}')
        if source.read(1):
            raise ValueError('input exceeds locked size')
    return digest.hexdigest(), size


def regular_file(entry):
    kind = stat.S_IFMT(entry.external_attr >> 16)
    return kind in (0, stat.S_IFREG) and not entry.is_dir()


def import_run16(archive, aot):
    lock = json.loads((aot / 'images.lock.json').read_text())
    bundle = lock['recorder_bundle']
    rows = lock['images']
    manifest = bundle['manifest_images']
    if lock['ish_commit'] != '0fd17a135e78b7a0cf08a4f5831217bbb76ed22f' or lock['abi'] != '1f3bb5a0':
        raise ValueError('unexpected pinned iSH commit or ABI')
    if len(rows) != 25 or len({r['module'] for r in rows}) != 25:
        raise ValueError('lock must contain exactly 25 unique catalog modules')
    if len(manifest) != 28 or len({m['file'] for m in manifest}) != 28:
        raise ValueError('lock must contain all 28 run16 manifest rows')
    if lock.get('inputs_available') is not False:
        raise ValueError('source images must remain external, not represented as Git-tracked')

    expected_members = {x['name']: x['size'] for x in bundle['archive_members']}
    if len(expected_members) != len(bundle['archive_members']):
        raise ValueError('duplicate member in locked archive table')
    source_names = {m['file'] for m in manifest}
    expected_set = source_names | {x[:-2] + '_ios.o' for x in source_names}
    if set(expected_members) != expected_set:
        raise ValueError('archive table is not exactly 28 assembly sources plus 28 object files')
    manifest_by_module = {m['module']: m for m in manifest}
    if len(manifest_by_module) != 28:
        raise ValueError('duplicate module in recorder manifest')
    excluded = set(bundle['excluded_modules'])
    selected = {r['module'] for r in rows}
    if selected & excluded or selected | excluded != set(manifest_by_module):
        raise ValueError('selected/excluded module lists do not partition the recorder manifest')

    stage = Path(tempfile.mkdtemp(prefix='.aojit-run16-', dir=aot))
    backups = []
    installed = []
    try:
        staged_zip = stage / 'run16.zip'
        with archive.open('rb') as src, staged_zip.open('wb') as dst:
            zip_sha, zip_size = hash_stream(src, bundle['image_zip_bytes'], dst)
        if zip_sha != bundle['image_zip_sha256']:
            raise ValueError('run16 archive SHA-256 mismatch')

        staged_sources = {}
        with zipfile.ZipFile(staged_zip) as archive_zip:
            entries = archive_zip.infolist()
            member_map = {x.filename: x for x in entries}
            if len(member_map) != len(entries) or set(member_map) != set(expected_members):
                raise ValueError('archive members differ from pinned run16 member set')
            for name, entry in member_map.items():
                if not regular_file(entry) or entry.file_size != expected_members[name]:
                    raise ValueError(f'{name}: unexpected ZIP type or size')

            # Verify every source header, including excluded modules. Per-image
            # SHA is required only for the 25 admitted modules; the pinned full
            # archive SHA protects all remaining bytes and the manifest pins
            # their header metadata.
            for record in manifest:
                name = record['file']
                if not re.fullmatch(r'aot_[A-Za-z0-9_.-]+\.S', name):
                    raise ValueError(f'{name}: invalid assembly filename')
                staged = stage / name
                with archive_zip.open(member_map[name]) as src, staged.open('xb') as dst:
                    digest, size = hash_stream(src, record['size'], dst)
                actual = info(str(staged))
                for key in ('module', 'family', 'abi', 'build_id', 'symbol', 'translations'):
                    if actual[key] != record[key]:
                        raise ValueError(f'{name}: manifest/header mismatch for {key}')
                if actual['abi'] != lock['abi'] or not actual['symbol'] or (actual['translations'] or 0) <= 0:
                    raise ValueError(f'{name}: unsupported ABI or empty translation table')
                row = next((r for r in rows if r['recorder_member'] == name), None)
                if row is None:
                    if record['module'] not in excluded or record.get('sha256') is not None:
                        raise ValueError(f'{name}: unexpected unselected recorder module')
                    continue
                if row['module'] != record['module'] or row['file'] in staged_sources:
                    raise ValueError(f'{name}: canonical module mapping is inconsistent')
                if row['sha256'] != record.get('sha256') or not row['sha256']:
                    raise ValueError(f'{name}: selected image SHA absent from lock manifest')
                if digest != row['sha256'] or row['recorder_bytes'] != size:
                    raise ValueError(f'{name}: selected source SHA/size mismatch')
                for key in ('family', 'build_id', 'recorder_symbol', 'translations'):
                    dest_key = 'symbol' if key == 'recorder_symbol' else key
                    if row[key] != record[dest_key]:
                        raise ValueError(f'{name}: selected image lock mismatch for {key}')
                staged_sources[name] = staged
            if set(staged_sources) != {r['recorder_member'] for r in rows}:
                raise ValueError('not all 25 selected source files were verified')

        # Validate every destination before changing any. Existing run7 images
        # are replaced only if they match their exact superseded SHA.
        pending = []
        for row in rows:
            target = aot / row['file']
            if target.is_symlink() or (target.exists() and not target.is_file()):
                raise ValueError(f'{target.name}: refusing non-regular destination')
            if target.exists():
                sha = hashlib.sha256()
                with target.open('rb') as f:
                    for chunk in iter(lambda: f.read(CHUNK), b''):
                        sha.update(chunk)
                current = sha.hexdigest()
                if current == row['sha256']:
                    continue
                if current != row.get('supersedes_sha256'):
                    raise ValueError(f'{target.name}: current bytes are not an admitted superseded image')
            pending.append((staged_sources[row['recorder_member']], target))

        for source, target in pending:
            if target.exists():
                backup = stage / (target.name + '.previous')
                os.replace(target, backup)
                backups.append((backup, target))
            os.replace(source, target)
            installed.append(target)
        print(f'PASS: pinned run16 archive and 28 manifest rows verified; {len(pending)} of 25 catalog images installed.')
        print('PASS: 3 excluded modules and 28 preassembled .o files were not installed.')
    except BaseException:
        for target in reversed(installed):
            try:
                target.unlink()
            except OSError:
                pass
        for backup, target in reversed(backups):
            if backup.exists():
                try:
                    os.replace(backup, target)
                except OSError:
                    pass
        raise
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    try:
        import_run16(args.archive, Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        parser.exit(2, f'ERROR: {exc}\n')


if __name__ == '__main__':
    main()
