"""Run the predeclared Windows/GCC experiment. No network or dependency installation."""
import argparse
import csv
import ctypes
from ctypes import wintypes as wt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time
from analyze import analyze, read_trials, render_report
from protocol import FILLS, SEED, SWEEPS, schedule

HERE = Path(__file__).resolve().parent
FLAGS = "-std=c++14 -O2 -DNDEBUG -fno-fast-math -ffp-contract=off -fno-lto -Wall -Wextra -Werror".split()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_source(src):
    hashes = json.loads((src / "provenance.json").read_text())["files_sha256"]
    for name, digest in hashes.items():
        if sha(src / name) != digest.lower():
            raise ValueError(f"Unexpected input: {name}")
    # These two text files may be checked out as CRLF or LF. Record raw hashes as well.
    for name, digest in {
        "check.cpp": "84a65f1c4898b397ca7dce330fc5cd7366806b3a71057b5ed9203cdea677517a",
        "dls_seed.hpp": "9ad6f54f449364b95138be3d85df62de55775b96dd50a705304b0460e84fc9e2",
    }.items():
        if hashlib.sha256((src / name).read_bytes().replace(b"\r\n", b"\n")).hexdigest() != digest:
            raise ValueError(f"Unexpected input: {name}")


def run(bin_dir, out):
    if os.name != "nt" or ctypes.sizeof(ctypes.c_void_p) != 8:
        raise ValueError("The benchmark requires native Windows x64 and 64-bit Python.")
    src = HERE.parent / "seed"
    lock = json.loads((HERE / "toolchain.lock.json").read_text())
    if any(os.environ.get(k) for k in
           "CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPATH CPLUS_INCLUDE_PATH COMPILER_PATH LIBRARY_PATH GCC_EXEC_PREFIX".split()):
        raise ValueError("Ambient compiler options are not allowed")
    gcc = bin_dir / "g++.exe"
    for name, digest in lock["bin_sha256"].items():
        if sha(bin_dir / name) != digest:
            raise ValueError(f"Tool does not match toolchain.lock.json: {name}")
    check_source(src)
    env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}
    out.mkdir(parents=True, exist_ok=False)
    scratch = out / "build"
    scratch.mkdir()

    def cmd(*args, timeout=90):
        return subprocess.run(args, cwd=scratch, env=env, check=True, text=True,
                              stdout=subprocess.PIPE, timeout=timeout).stdout

    if cmd(gcc, "-dumpmachine").strip() != lock["target"]:
        raise ValueError("Unexpected target")
    version = cmd(gcc, "--version").splitlines()[0]
    objects = {}
    asm = {}
    for v, name in zip("AB", ("original", "cached")):
        obj = scratch / (name + ".obj")
        cmd(gcc, *FLAGS, "-c", src / (name + ".cpp"), "-o", obj)
        objects[v] = obj
        sym = "dls_seed_" + name
        listing = cmd(bin_dir / "objdump.exe", "-d", "--no-show-raw-insn", "--disassemble=" + sym, obj)
        instructions = re.findall(r"^\s*[0-9a-f]+:\s+([a-z][a-z0-9.]*)\b", listing, re.M)
        if not instructions or not any(op.startswith("ret") for op in instructions) or f"<{sym}>:" not in listing:
            raise ValueError(f"Could not isolate {sym}")
        asm[v] = dict(symbol=sym, instructions_in_listing=len(instructions),
                      conditional_branches=[op for op in instructions if
                                            (op.startswith("j") and not op.startswith("jmp")) or op.startswith("loop")],
                      jumps=[op for op in instructions if op.startswith("jmp")],
                      calls=[op for op in instructions if op.startswith("call")],
                      returns=[op for op in instructions if op.startswith("ret")], object_sha256=sha(obj))
        (scratch / (name + ".asm")).write_text(listing)
    cmd(gcc, *FLAGS, src / "check.cpp", objects["A"], objects["B"], "-o", "fresh.exe")
    cmd(gcc, *FLAGS, "-I", src, "-c", HERE / "warm.cpp", "-o", "warm.obj")
    linked = {}
    for layout in ("AB", "BA"):
        cmd(gcc, "warm.obj", *(objects[v] for v in layout), "-o", f"warm{layout}.exe")
        syms = cmd(bin_dir / "nm.exe", "-n", f"warm{layout}.exe")
        names = re.findall(r"^([a-fA-F0-9]+)\s+T\s+dls_seed_(original|cached)$", syms, re.M)
        if "".join("A" if name == "original" else "B" for _, name in names) != layout:
            raise ValueError(f"Link layout {layout} was not realized")
        linked[layout] = {name: addr for addr, name in names}

    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.GetCurrentProcess.restype = wt.HANDLE
    k.GetProcessAffinityMask.argtypes = [wt.HANDLE, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
    k.SetProcessAffinityMask.argtypes = [wt.HANDLE, ctypes.c_size_t]
    handle = k.GetCurrentProcess()
    k.IsWow64Process2.argtypes = [wt.HANDLE, ctypes.POINTER(wt.USHORT), ctypes.POINTER(wt.USHORT)]
    process_machine, native_machine = wt.USHORT(), wt.USHORT()
    if not k.IsWow64Process2(handle, ctypes.byref(process_machine), ctypes.byref(native_machine)):
        raise ctypes.WinError(ctypes.get_last_error())
    if process_machine.value != 0 or native_machine.value != 0x8664:
        raise ValueError("Emulated or non-x64 Windows is outside this protocol")
    allowed, system = ctypes.c_size_t(), ctypes.c_size_t()
    if not k.GetProcessAffinityMask(handle, ctypes.byref(allowed), ctypes.byref(system)):
        raise ctypes.WinError(ctypes.get_last_error())
    eligible = allowed.value & ~1 or allowed.value
    mask = eligible & -eligible
    cpu = mask.bit_length() - 1

    power_before = cmd("powercfg.exe", "/getactivescheme").strip()
    started = time.time()
    if not k.SetProcessAffinityMask(handle, mask):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        with (out / "trials.csv").open("x", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow("arm launch layout block order pair slot variant ns ns_per_fill".split())
            for arm, layout, slots in schedule():
                if arm == "fresh":
                    for row in slots:
                        name = "original" if row[-1] == "A" else "cached"
                        line = cmd(scratch / "fresh.exe", name, str(SWEEPS)).strip()
                        m = re.fullmatch(rf"PASS {name} {SWEEPS} 40 ([1-9]\d*)", line)
                        if not m:
                            raise ValueError(line)
                        ns = int(m[1])
                        writer.writerow((*row, ns, ns/FILLS))
                else:
                    seq = "".join(row[-1] for row in slots)
                    lines = cmd(scratch / f"warm{layout}.exe", seq).splitlines()
                    if len(lines) != len(slots):
                        raise ValueError("Incomplete warm process")
                    for row, line in zip(slots, lines):
                        v, ns, before, after = line.split()
                        ns = int(ns)
                        if ns <= 0 or v != row[-1] or (int(before), int(after)) != (cpu, cpu):
                            raise ValueError("Duration, order or CPU mismatch: " + line)
                        writer.writerow((*row, ns, ns/FILLS))
                stream.flush()
    finally:
        if not k.SetProcessAffinityMask(handle, allowed.value):
            raise ctypes.WinError(ctypes.get_last_error())
    if cmd("powercfg.exe", "/getactivescheme").strip() != power_before:
        raise ValueError("Power plan changed")
    try:
        pmcs = cmd("wpr.exe", "-pmcsources")
    except FileNotFoundError:
        pmcs = "WPR is not installed; no counter inventory available.\n"
    (out / "pmc.txt").write_text(pmcs)
    meta = dict(gcc=version, compiler_sha256=sha(gcc), flags=FLAGS, seed=SEED,
                seed_revision="23825a7ccb5aa5348ae5c99b1462ac3d2c656104",
                os=platform.platform(), python=platform.python_version(), link_order=linked,
                source_sha256={p.name: sha(p) for p in src.iterdir() if p.is_file()},
                probe_sha256={name: sha(HERE / name) for name in
                              ("run.py", "analyze.py", "protocol.py", "warm.cpp", "toolchain.lock.json")},
                allowed_mask=hex(allowed.value), cpu=cpu, power_scheme=power_before, started_epoch=started,
                finished_epoch=time.time(), disassembly=asm,
                exe_hashes={p.name: sha(p) for p in scratch.glob("*.exe")})
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    summary = analyze(out / "trials.csv")
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    report = render_report(summary, read_trials(out / "trials.csv")[0])
    (out / "report.txt").write_text(report, encoding="utf-8")
    print(report, end="")
    print(f"Results: {out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("bin", "out"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    run(args.bin.resolve(), args.out.resolve())
