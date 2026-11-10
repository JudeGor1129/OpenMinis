#!/usr/bin/env python3
"""Deterministic Mach-O slice report for a rootless tweak DEB."""
import hashlib, json, struct, sys, pathlib

def ar_members(data):
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    pos, out = 8, {}
    while pos + 60 <= len(data):
        h = data[pos:pos+60]
        name = h[:16].decode().strip().rstrip("/")
        size = int(h[48:58])
        out[name] = data[pos+60:pos+60+size]
        pos += 60 + size + (size & 1)
    return out

def tar_file(tar, suffix):
    pos = 0
    while pos + 512 <= len(tar):
        h = tar[pos:pos+512]
        if h[:100].strip(b"\0") == b"":
            break
        name = h[:100].rstrip(b"\0/").decode()
        size = int(h[124:136].strip(b"\0 ") or b"0", 8)
        if name.endswith(suffix):
            return name, tar[pos+512:pos+512+size]
        pos += 512 + ((size + 511) // 512) * 512
    raise SystemExit("missing " + suffix)

def thin(sl):
    n = struct.unpack_from("<I", sl, 16)[0]
    cur, cmds = 32, []
    for _ in range(n):
        cmd, size = struct.unpack_from("<II", sl, cur)
        cmds.append({"cmd": hex(cmd), "size": size})
        cur += size
    return {
        "subtype": hex(struct.unpack_from("<I", sl, 8)[0]),
        "bytes": len(sl),
        "sha256": hashlib.sha256(sl).hexdigest(),
        "loadCommands": cmds,
        "hasDyldInfoOnly": any(c["cmd"] == "0x80000022" for c in cmds),
        "hasChainedFixups": any(c["cmd"] == "0x80000034" for c in cmds),
        "pacibsp": sl.count(bytes.fromhex("7f2303d5")),
        "autibsp": sl.count(bytes.fromhex("ff2303d5")),
    }

def main(path):
    data = pathlib.Path(path).read_bytes()
    tar = ar_members(data)["data.tar"]
    name, dylib = tar_file(tar, "PetSmoke.dylib")
    magic = struct.unpack_from(">I", dylib, 0)[0]
    slices = []
    if magic == 0xcafebabe:
        n = struct.unpack_from(">I", dylib, 4)[0]
        for i in range(n):
            cpu, sub, off, size, align = struct.unpack_from(">IIIII", dylib, 8+i*20)
            slices.append({"arch": hex(cpu), **thin(dylib[off:off+size])})
    else:
        slices.append({"arch": hex(struct.unpack_from("<I", dylib, 4)[0]), **thin(dylib)})
    print(json.dumps({
        "deb": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
        "payload": name,
        "dylibBytes": len(dylib),
        "fatMagic": hex(magic),
        "slices": slices,
    }, indent=2, sort_keys=True))

if __name__ == "__main__":
    main(sys.argv[1])
