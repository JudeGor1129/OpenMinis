#!/usr/bin/env python3
"""Independent standard-library/ar/lipo-readable validation of Swift fixtures.
Synthetic slices are explicitly not native compilation or plugin-use evidence.
"""
import hashlib, io, json, pathlib, plistlib, struct, sys, tarfile
root = pathlib.Path(sys.argv[1])
meta = json.loads((root/'contract-metadata.json').read_text())
evidence = json.loads((root/'contract-evidence.json').read_text())
deb = (root/'contract.deb').read_bytes()
assert deb[:8] == b'!<arch>\n'
cursor = 8
members = {}
while cursor < len(deb):
    head = deb[cursor:cursor+60]
    assert len(head) == 60 and head[58:] == b'`\n'
    name = head[:16].decode('ascii').strip().removesuffix('/')
    size = int(head[48:58].decode('ascii').strip())
    cursor += 60
    assert 0 <= size <= len(deb)-cursor and name not in members
    members[name] = deb[cursor:cursor+size]
    cursor += size
    if size % 2:
        assert deb[cursor:cursor+1] == b'\n'
        cursor += 1
assert cursor == len(deb)
assert list(members) == ['debian-binary', 'control.tar', 'data.tar']
assert members['debian-binary'] == b'2.0\n'
with tarfile.open(fileobj=io.BytesIO(members['control.tar']), mode='r:') as tar:
    assert tar.getnames() == ['control']
    item = tar.getmember('control')
    assert item.isfile() and item.mode == 0o644 and item.uid == item.gid == 0
    control = dict(line.split(': ', 1) for line in tar.extractfile(item).read().decode().splitlines())
assert control['Package'] == meta['packageID'] and control['Version'] == meta['version']
assert control['Architecture'] == 'iphoneos-arm64' and control['Depends'] == 'firmware (>= 15.0), mobilesubstrate'
prefix = 'var/jb/Library/MobileSubstrate/DynamicLibraries'
paths = ['var', 'var/jb', 'var/jb/Library', 'var/jb/Library/MobileSubstrate', prefix,
         prefix+'/'+meta['tweakName']+'.dylib', prefix+'/'+meta['tweakName']+'.plist']
with tarfile.open(fileobj=io.BytesIO(members['data.tar']), mode='r:') as tar:
    assert tar.getnames() == paths
    for i, item in enumerate(tar):
        assert item.uid == item.gid == 0
        assert (item.isdir() if i < 5 else item.isfile())
        assert item.mode == (0o644 if i == 6 else 0o755)
    fat = tar.extractfile(paths[5]).read()
    filt = plistlib.loads(tar.extractfile(paths[6]).read())
assert filt == {'Filter': {'Bundles': meta['bundleIDs']}}
assert fat == (root/'contract-fat.dylib').read_bytes()
magic, count = struct.unpack_from('>II', fat)
assert magic == 0xcafebabe and count == 2
for i, subtype in enumerate([0, 0x80000002]):
    cpu, sub, off, size, align = struct.unpack_from('>IIIII', fat, 8+i*20)
    assert cpu == 0x100000c and sub == subtype and align == 14 and off % (1 << align) == 0
    thin = fat[off:off+size]
    assert len(thin) == size
    header = struct.unpack_from('<IIIIIIII', thin)
    assert header[0:4] == (0xfeedfacf, cpu, sub, 6)
    item = evidence['universal']['slices'][i]
    assert item['offset'] == off and item['bytes'] == size and item['cpuSubtype'] == sub
    assert hashlib.sha256(thin).hexdigest() == item['sha256']
assert hashlib.sha256(fat).hexdigest() == evidence['universal']['sha256']
assert hashlib.sha256(deb).hexdigest() == evidence['sha256']
assert evidence['bytes'] == len(deb)
print('PASS: independent Python ar/ustar/plist/FAT payload, permissions and per-slice hashes')
print('NOTE: synthetic container evidence only; no native compiler or plugin runtime claim')
