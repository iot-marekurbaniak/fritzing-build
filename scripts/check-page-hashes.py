"""Check the code-signature page hashes of every Mach-O file in an app bundle.

dyld kills a process (SIGKILL, Code Signature Invalid) when a mapped page does not match the hash in
the file's CodeDirectory. GitHub runners do not enforce this, so a stale signature passes every other
build step. `codesign --verify` is no substitute: it also checks the sealed resources of each framework,
which macdeployqt legitimately changes, and those are not checked when a library is loaded.

usage: check-page-hashes.py <bundle> <arch>   (arch: arm64 requires every Mach-O to be signed)
"""
import hashlib
import struct
import sys
from pathlib import Path

CPU = {0x0100000C: "arm64", 0x01000007: "x86_64"}
LC_CODE_SIGNATURE = 0x1D
HASHES = {1: hashlib.sha1, 2: hashlib.sha256}


def check_slice(data: bytes) -> str:
    """'ok', 'unsigned' or a description of the mismatch for one thin Mach-O image."""
    ncmds = struct.unpack("<I", data[16:20])[0]
    offset, signature = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<2I", data[offset:offset + 8])
        if cmd == LC_CODE_SIGNATURE:
            signature = struct.unpack("<2I", data[offset + 8:offset + 16])
        offset += size
    if signature is None:
        return "unsigned"
    blob = data[signature[0]:signature[0] + signature[1]]
    count = struct.unpack(">I", blob[8:12])[0]
    for i in range(count):
        slot, start = struct.unpack(">2I", blob[12 + 8 * i:20 + 8 * i])
        if slot != 0:  # the primary CodeDirectory
            continue
        cd = blob[start:]
        hash_offset, _, _, n_code, code_limit = struct.unpack(">5I", cd[16:36])
        hash_size, hash_type, page_shift = cd[36], cd[37], cd[39]
        page = 1 << page_shift
        bad = sum(
            HASHES[hash_type](data[p * page:min((p + 1) * page, code_limit)]).digest()[:hash_size]
            != cd[hash_offset + p * hash_size:hash_offset + (p + 1) * hash_size]
            for p in range(n_code))
        return "ok" if bad == 0 else f"{bad}/{n_code} pages differ from the signature"
    return "no CodeDirectory"


def main() -> None:
    bundle, arch = Path(sys.argv[1]), sys.argv[2]
    failures, checked = [], 0
    for path in sorted(p for p in bundle.rglob("*") if p.is_file() and not p.is_symlink()):
        data = path.read_bytes()
        if data[:4] == b"\xca\xfe\xba\xbe":  # universal binary: check the slice dyld will load
            slices = {}
            for i in range(struct.unpack(">I", data[4:8])[0]):
                cpu, _, start, size, _ = struct.unpack(">5I", data[8 + 20 * i:28 + 20 * i])
                slices[CPU.get(cpu)] = data[start:start + size]
            if arch not in slices:
                failures.append(f"{path}: no {arch} slice")
                continue
            data = slices[arch]
        elif data[:4] != b"\xcf\xfa\xed\xfe":
            continue
        checked += 1
        result = check_slice(data)
        if result == "ok" or (result == "unsigned" and arch == "x86_64"):
            continue
        failures.append(f"{path}: {result}")
    print(f"checked {checked} Mach-O files for {arch}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
