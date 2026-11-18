#!/usr/bin/env python3
"""Deterministic binary & config patcher for BlueStacks Air Chrome/AppZygote compatibility."""

import argparse
import hashlib
import json
import os
import struct
import sys

ORIG_RUNTIME_SHA = "f9c9745941b92a6350bc4490682de169c6716dd9d3e89b877b80056754e65df1"
PATCHED_RUNTIME_SHA = "487dc1f4f69302e00aabe8c2b28b18d0d6324ad0d1b0f7de5583e325a677f5c2"

ORIG_BINDER_SHA = "a26321bfe4a7a1199fc337d568fb870942ab16084a83467c331a12da35a763f7"
PATCHED_BINDER_SHA = "7fd7862bcfd20ed971a33aeb1a794cf959bcd1e14b7b11ffd29f1920dfbdfafb"


def _b_imm26(pc: int, target: int) -> int:
    off = (target - pc) >> 2
    if not (-(1 << 25) <= off < (1 << 25)):
        raise ValueError(f"Branch offset out of 26-bit range: {pc:#x} -> {target:#x}")
    return 0x14000000 | (off & 0x03FFFFFF)


def _bl_imm26(pc: int, target: int) -> int:
    off = (target - pc) >> 2
    if not (-(1 << 25) <= off < (1 << 25)):
        raise ValueError(f"Call offset out of 26-bit range: {pc:#x} -> {target:#x}")
    return 0x94000000 | (off & 0x03FFFFFF)


def _b_cond(pc: int, target: int, cond: int) -> int:
    off = (target - pc) >> 2
    if not (-(1 << 18) <= off < (1 << 18)):
        raise ValueError(f"Conditional branch offset out of 19-bit range: {pc:#x} -> {target:#x}")
    return 0x54000000 | ((off & 0x7FFFF) << 5) | cond


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_libandroid_runtime(data: bytearray) -> bytes:
    """Skip SpecializeCommon's BstFilterAppsManager call for AppZygotes and isolated processes."""
    if data[0x1CF3A8:0x1CF3AC] != bytes.fromhex("032c0054"):
        raise ValueError("Unexpected instruction at libandroid_runtime.so+0x1cf3a8")
    cave = 0x200C00
    if data[cave : cave + 48] != b"\x00" * 48:
        raise ValueError("Expected zero padding cave at libandroid_runtime.so+0x200c00")

    struct.pack_into("<I", data, 0x1CF3A8, _b_imm26(0x1CF3A8, cave))
    insns = [
        _b_cond(cave + 0x00, 0x1CF928, 3),  # b.lo 0x1cf928 (uid < 10000)
        0x7200037F,                         # tst w27, #1 (is_child_zygote)
        _b_cond(cave + 0x08, 0x1CF928, 1),  # b.ne 0x1cf928
        0x5290D409,                         # mov w9, #0x86a0
        0x72A00029,                         # movk w9, #1, lsl #16 (w9 = 100000)
        0x1AC90B4A,                         # udiv w10, w26, w9
        0x1B09E949,                         # msub w9, w10, w9, w26 (appId = uid % 100000)
        0x53047D29,                         # lsr w9, w9, #4
        0x5282BF2A,                         # mov w10, #0x15f9 (90000 >> 4)
        0x6B0A013F,                         # cmp w9, w10
        _b_cond(cave + 0x28, 0x1CF928, 2),  # b.hs 0x1cf928 (isolatedProcess)
        _b_imm26(cave + 0x2C, 0x1CF3AC),    # b 0x1cf3ac
    ]
    for idx, insn in enumerate(insns):
        struct.pack_into("<I", data, cave + idx * 4, insn)
    return bytes(data)


def patch_libbinder(data: bytearray) -> bytes:
    """Return nullptr from BstFilterAppsManager::getService() for *_zygote and isolated/system UIDs."""
    if data[0x5E858:0x5E85C] != bytes.fromhex("ff8301d1"):
        raise ValueError("Unexpected prologue at libbinder.so+0x5e858")
    cave = 0x0BED70
    # 38 instructions = 152 bytes
    if data[cave : cave + 152] != b"\x00" * 152:
        raise ValueError("Expected zero padding cave at libbinder.so+0x0bed70")

    struct.pack_into("<I", data, 0x5E858, _b_imm26(0x5E858, cave))
    words = [
        0xA9BD7BFD,                         # stp x29, x30, [sp, #-0x30]!
        0xA90123E0,                         # stp x0, x8, [sp, #0x10]
        0xF90013F3,                         # str x19, [sp, #0x20]
        _bl_imm26(cave + 3 * 4, 0xBBF10),   # bl getuid@plt
        0x5290D409,                         # mov w9, #0x86a0
        0x72A00029,                         # movk w9, #1, lsl #16 (w9 = 100000)
        0x1AC9080A,                         # udiv w10, w0, w9
        0x1B098149,                         # msub w9, w10, w9, w0 (appId)
        0x53047D29,                         # lsr w9, w9, #4
        0x7109C53F,                         # cmp w9, #0x271 (appId < 10000)
        0x540002E3,                         # b.lo ret_null (+0x5c -> +33*4)
        0x5282BF2A,                         # mov w10, #0x15f9 (90000 >> 4)
        0x6B0A013F,                         # cmp w9, w10
        0x54000282,                         # b.hs ret_null
        _bl_imm26(cave + 14 * 4, 0xBEB90),  # bl getprogname@plt
        0xB40001A0,                         # cbz x0, normal
        0xAA0003F3,                         # mov x19, x0
        _bl_imm26(cave + 17 * 4, 0xBC270),  # bl strlen@plt
        0xF1001C1F,                         # cmp x0, #7
        0x54000123,                         # b.lo normal
        0x8B000261,                         # add x1, x19, x0
        0xF85F902A,                         # ldur x10, [x1, #-7]
        0xD28F4BE9,                         # mov x9, #0x7a5f
        0xF2ACEF29,                         # movk x9, #0x6779, lsl #16
        0xF2CE8DE9,                         # movk x9, #0x746f, lsl #32
        0xF2E00CA9,                         # movk x9, #0x0065, lsl #48 ("_zygote\0")
        0xEB09015F,                         # cmp x10, x9
        0x540000C0,                         # b.eq ret_null
        # normal:
        0xF94013F3,                         # ldr x19, [sp, #0x20]
        0xA94123E0,                         # ldp x0, x8, [sp, #0x10]
        0xA8C37BFD,                         # ldp x29, x30, [sp], #0x30
        0xD10183FF,                         # sub sp, sp, #0x60
        _b_imm26(cave + 32 * 4, 0x5E85C),   # b 0x5e85c
        # ret_null:
        0xF94013F3,                         # ldr x19, [sp, #0x20]
        0xA94123E0,                         # ldp x0, x8, [sp, #0x10]
        0xA8C37BFD,                         # ldp x29, x30, [sp], #0x30
        0xF900011F,                         # str xzr, [x8]
        0xD65F03C0,                         # ret
    ]
    for idx, word in enumerate(words):
        struct.pack_into("<I", data, cave + idx * 4, word)
    return bytes(data)


def cmd_patch_libs(args: argparse.Namespace) -> int:
    with open(args.runtime_in, "rb") as f:
        rt_raw = f.read()
    with open(args.binder_in, "rb") as f:
        bd_raw = f.read()

    rt_sha = sha256_bytes(rt_raw)
    bd_sha = sha256_bytes(bd_raw)

    if rt_sha == PATCHED_RUNTIME_SHA and bd_sha == PATCHED_BINDER_SHA:
        return 2

    if rt_sha != ORIG_RUNTIME_SHA or bd_sha != ORIG_BINDER_SHA:
        print(
            f"Unsupported ROM library hashes (runtime={rt_sha}, binder={bd_sha}); "
            "skipping bsair_appzygote_fix to avoid mismatch.",
            file=sys.stderr,
        )
        return 3

    rt_patched = patch_libandroid_runtime(bytearray(rt_raw))
    bd_patched = patch_libbinder(bytearray(bd_raw))

    if sha256_bytes(rt_patched) != PATCHED_RUNTIME_SHA:
        raise RuntimeError("Patched libandroid_runtime.so checksum mismatch")
    if sha256_bytes(bd_patched) != PATCHED_BINDER_SHA:
        raise RuntimeError("Patched libbinder.so checksum mismatch")

    with open(args.runtime_out, "wb") as f:
        f.write(rt_patched)
    with open(args.binder_out, "wb") as f:
        f.write(bd_patched)
    return 0


def cmd_unblacklist_chrome(args: argparse.Namespace) -> int:
    with open(args.inp, "r", encoding="utf-8") as f:
        doc = json.load(f)

    packages = doc.get("packages")
    if not isinstance(packages, list):
        print("Invalid config.db JSON: missing packages list", file=sys.stderr)
        return 1

    changed = False
    for entry in packages:
        if entry.get("pkgname") != "com.android.chrome":
            continue
        rules = entry.get("rules")
        if not isinstance(rules, list):
            continue
        kept = []
        for rule in rules:
            oems = [o.strip() for o in str(rule.get("oems", "")).split(",") if o.strip()]
            if rule.get("blacklist") == "*" and "nxt_mac2" in oems:
                changed = True
                continue
            kept.append(rule)
        entry["rules"] = kept

    if not changed:
        return 2

    tmp_out = f"{args.out}.tmp.{os.getpid()}"
    with open(tmp_out, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp_out, args.out)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_libs = sub.add_parser("patch-libs")
    p_libs.add_argument("--runtime-in", required=True)
    p_libs.add_argument("--runtime-out", required=True)
    p_libs.add_argument("--binder-in", required=True)
    p_libs.add_argument("--binder-out", required=True)
    p_libs.set_defaults(func=cmd_patch_libs)

    p_chrome = sub.add_parser("unblacklist-chrome")
    p_chrome.add_argument("--in", dest="inp", required=True)
    p_chrome.add_argument("--out", required=True)
    p_chrome.set_defaults(func=cmd_unblacklist_chrome)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
