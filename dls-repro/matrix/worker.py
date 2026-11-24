"""Build and measure one selected native/WSL environment. Uses Python standard library only."""
import argparse
from collections import defaultdict
import csv
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
from statistics import mean, median
import subprocess
import sys
import tempfile
import time

PKG = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PKG / "order-probe"))
from analyze import contrasts, summarize_strata
from protocol import PAIRS
from run import check_source, sha

GNU_FLAGS = "-std=c++14 -O2 -DNDEBUG -fno-fast-math -ffp-contract=off -fno-lto -Wall -Wextra -Werror".split()
MS_FLAGS = "/nologo /std:c++14 /O2 /Ob2 /Gy- /MD /EHa /fp:precise /DNDEBUG /W4 /WX".split()
COLUMNS = "launch layout block order pair slot variant pid cpu ns ns_per_fill process_cpu_ns peak_rss_bytes".split()
VS_RANGES = {"2019": (1920, 1930), "2022": (1930, 1950), "2026": (1950, 2000)}


def limits(launches, blocks, sweeps):
    if not (2 <= launches <= 32 and launches % 2 == 0 and 1 <= blocks <= 64 and 1 <= sweeps <= 10000):
        raise ValueError("Expected even launches (2..32), blocks (1..64), sweeps (1..10000)")


def same_result(actual, recorded):
    if type(actual) is not type(recorded):
        return False
    if isinstance(actual, dict):
        return actual.keys() == recorded.keys() and all(same_result(v, recorded[k]) for k, v in actual.items())
    if isinstance(actual, list):
        return len(actual) == len(recorded) and all(same_result(x, y) for x, y in zip(actual, recorded))
    if isinstance(actual, float):
        # Windows and Linux libm can differ by a few ULPs on the same log/exp inputs.
        return math.isclose(actual, recorded, rel_tol=1e-12, abs_tol=1e-12)
    return actual == recorded


def replay(directory):
    meta = json.loads((directory / "summary.json").read_text(encoding="utf-8"))
    with (directory / "trials.csv").open(newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != COLUMNS:
            raise ValueError("Unexpected CSV header")
        rows = [{k: (v if k in ("layout", "pair", "variant") else
                     float(v) if k == "ns_per_fill" else int(v)) for k, v in row.items()} for row in reader]
    recomputed = summarize(rows, meta["launches"], meta["blocks"], meta["sweeps"], meta["seed"])
    if meta["status"] != "passed" or any(not same_result(value, meta[key]) for key, value in recomputed.items()):
        raise ValueError("Raw observations do not reproduce the recorded result")
    print(f"Verified {len(rows)} slots: {directory.name}")


def schedule(launches, blocks, seed):
    rng = random.Random(seed)
    for launch in range(launches):
        layout = ("AB", "BA")[launch % 2]
        slots = [(launch, layout, block, order, pair, slot, variant)
                 for block in range(blocks) for order, pair in enumerate(rng.sample(PAIRS, len(PAIRS)))
                 for slot, variant in enumerate(pair, 1)]
        yield layout, slots


def summarize(rows, launches, blocks, sweeps, seed):
    expected = [s for _, slots in schedule(launches, blocks, seed) for s in slots]
    if len(rows) != len(expected):
        raise ValueError("Missing or extra slots")
    grouped = defaultdict(dict)
    pids, cpus = defaultdict(set), set()
    for r, slot in zip(rows, expected):
        if tuple(r[k] for k in COLUMNS[:7]) != slot or r["ns"] <= 0 or r["ns_per_fill"] != r["ns"] / (40*sweeps):
            raise ValueError("Invalid slot/order/duration")
        if r["pid"] <= 0 or r["cpu"] < 0 or r["process_cpu_ns"] < 0 or r["peak_rss_bytes"] <= 0:
            raise ValueError("Missing process, CPU or memory observation")
        l, layout, b, _, pair, pos, _ = slot
        grouped[layout, l, b].setdefault(pair, {})[pos] = r["ns"]
        pids[l].add(r["pid"])
        cpus.add(r["cpu"])
    if len(cpus) != 1 or any(len(values) != 1 for values in pids.values()):
        raise ValueError("A slot migrated CPU or a launch mixed processes")
    clusters = defaultdict(list)
    for (layout, launch, _), pairs in grouped.items():
        clusters[layout, launch].append(contrasts({p: math.log(s[2] / s[1]) for p, s in pairs.items()}))
    metrics = {}
    for name in next(iter(clusters.values()))[0]:
        strata = defaultdict(list)
        for (layout, _), records in sorted(clusters.items()):
            strata[layout].append(mean(r[name] for r in records))
        metrics[name] = summarize_strata(strata, seed)
    return dict(slots=len(rows), fills_per_slot=40*sweeps, cpu=cpus.pop(), launches=launches,
                median_ns_per_fill={v: median(r["ns_per_fill"] for r in rows
                                              if r["variant"] == v and r["pair"] in ("AB", "BA")) for v in "AB"},
                contrasts_pct=metrics)


def execute(a):
    limits(a.launches, a.blocks, a.sweeps)
    if a.cpu < -1 or a.cpu > 1023 or not 0 <= a.seed <= 2147483647:
        raise ValueError("Invalid CPU or seed")
    if a.system == "wsl":
        if sys.platform != "linux" or "microsoft" not in platform.release().lower():
            raise ValueError("Expected native Linux under WSL")
    elif os.name != "nt":
        raise ValueError("Expected native Windows")
    for k in "CL _CL_ LINK _LINK_ CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPATH CPLUS_INCLUDE_PATH COMPILER_PATH LIBRARY_PATH GCC_EXEC_PREFIX CCC_OVERRIDE_OPTIONS".split():
        if os.environ.get(k):
            raise ValueError("Uncontrolled tool override: " + k)
    found = shutil.which(a.compiler)
    if not found:
        raise ValueError(f"{a.system}: C++ compiler not found: {a.compiler}")
    # Keep the driver name (clang++ and clang can be links to the same binary).
    cc = Path(found).absolute()
    env = {**os.environ, "PATH": str(cc.parent) + os.pathsep + os.environ["PATH"]}
    src, warm = PKG / "seed", PKG / "order-probe" / "warm.cpp"
    check_source(src)
    msvc = a.family == "msvc"
    a.out.mkdir(exist_ok=False)
    flags = MS_FLAGS if msvc else GNU_FLAGS
    rows = []
    selected = a.cpu
    layouts = {}
    started = time.time()
    with tempfile.TemporaryDirectory(prefix="dls-warm-") as work:
        def cmd(args, timeout=180):
            p = subprocess.run([str(x) for x in args], cwd=work, env=env, text=True, errors="replace",
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            if p.returncode:
                raise RuntimeError(f"Exit {p.returncode}: {args[0]}\n{(p.stdout+p.stderr)[-2000:]}")
            return p.stdout

        if msvc:
            # cl /? prints a localized banner. The front-end macro below is locale independent.
            macro = Path(work) / "version.cpp"
            macro.write_text("_MSC_FULL_VER\n", encoding="ascii")
            version = cmd([cc, "/nologo", "/EP", macro]).strip()
            if not re.fullmatch(r"19\d{7}", version):
                raise ValueError(f"Unexpected _MSC_FULL_VER: {version}")
            lower, upper = VS_RANGES[a.year]
            if not lower <= int(version[:4]) < upper:
                raise ValueError(f"Wrong MSVC for VS {a.year}: {version}")
            target = os.environ.get("VSCMD_ARG_TGT_ARCH")
        else:
            version = cmd([cc, "--version"]).splitlines()[0]
            target = cmd([cc, "-dumpmachine"]).strip()
            macros = cmd([cc, "-dM", "-E", "-x", "c++", "NUL" if os.name == "nt" else "/dev/null"])
            is_clang = "#define __clang__ " in macros
            if "#define __GNUC__ " not in macros or is_clang != (a.family == "clang"):
                raise ValueError(f"Driver does not match requested {a.family}: {version}")
            if (a.system == "wsl") != ("linux" in target) or (a.system == "windows" and not re.search("mingw|windows", target)):
                raise ValueError("Wrong compiler target: " + target)
        objects = {}
        for key, file in (("A",src/"original.cpp"), ("B",src/"cached.cpp"), ("W",warm)):
            obj = key + ".obj"
            args = ["/I"+str(src), "/c", file, "/Fo"+obj] if msvc else ["-I",src,"-c",file,"-o",obj]
            cmd([cc,*flags,*args])
            objects[key] = obj
        binaries = {}
        for layout in ("AB","BA"):
            exe = Path(work) / ("warm" + layout + (".exe" if os.name == "nt" else ""))
            tail = ["/Fe"+str(exe),"/link","/INCREMENTAL:NO","/OPT:NOICF"] if msvc else ["-o",exe]
            cmd([cc,*(["/nologo"] if msvc else []),objects["W"],*(objects[v] for v in layout),*tail])
            binaries[layout] = exe
        with (a.out/"trials.csv").open("x",newline="") as f:
            writer = csv.DictWriter(f, fieldnames=COLUMNS)
            writer.writeheader()
            for layout, slots in schedule(a.launches, a.blocks, a.seed):
                seq = "".join(row[-1] for row in slots)
                lines = cmd([binaries[layout],seq,a.sweeps,selected], timeout=max(90, len(seq)*a.sweeps//250)).splitlines()
                if len(lines) != 1+len(seq):
                    raise ValueError("Missing native checker slots")
                passed = re.fullmatch(r"PASS (\d+) (\d+) 40 (AB|BA)",lines[0])
                if not passed or (selected != -1 and int(passed[2]) != selected):
                    raise ValueError("Failed fixture, CPU or result validation: " + lines[0])
                selected, pid = int(passed[2]), int(passed[1])
                if passed[3] != layout:
                    raise ValueError(f"Requested link order {layout}, observed {passed[3]}")
                layouts[layout] = passed[3]
                for slot, line in zip(slots, lines[1:]):
                    variant, duration, c0, c1, cpu_ns, rss = line.split()
                    ns = int(duration)
                    if variant != slot[-1] or ns <= 0 or (int(c0),int(c1)) != (selected,selected):
                        raise ValueError("Native CPU/order/duration mismatch")
                    row = dict(zip(COLUMNS, (*slot,pid,selected,ns,ns/(40*a.sweeps),int(cpu_ns),int(rss))))
                    writer.writerow(row)
                    rows.append(row)
                f.flush()
        if len(set(layouts.values())) != 2:
            raise ValueError(f"Linker did not produce two distinct function orders: {layouts}")
        artifacts = {layout:sha(exe) for layout,exe in binaries.items()}
    stats = summarize(rows,a.launches,a.blocks,a.sweeps,a.seed)
    stats.update(status="passed",compiler=str(cc),version=version,target=target,system=a.system,family=a.family,
                 vs_year=a.year,os=platform.platform(),kernel=platform.release(),compiler_sha256=sha(cc),
                 flags=flags,actual_layouts=layouts,exe_sha256=artifacts,blocks=a.blocks,sweeps=a.sweeps,
                 seed=a.seed,started=started,finished=time.time(),warmup_ms=1000,conditioning_sweeps=16,
                 source_sha256={p.name:sha(p) for p in (src/"original.cpp",src/"cached.cpp",src/"check.cpp",src/"dls_seed.hpp",warm)})
    (a.out/"summary.json").write_text(json.dumps(stats,indent=2)+"\n",encoding="utf-8")
    lines = ["launch block order pair | first / second (ns/fill)"]
    for first,second in zip(rows[::2],rows[1::2]):
        lines.append(f"{first['launch']:6} {first['block']:5} {first['order']:5} {first['pair']:4} | "
                     f"{first['ns_per_fill']:.3f} / {second['ns_per_fill']:.3f}")
    lines.append(json.dumps(stats["contrasts_pct"],indent=2))
    (a.out/"report.txt").write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--replay":
        replay(Path(sys.argv[2]))
        sys.exit(0)
    p = argparse.ArgumentParser(description=__doc__, epilog="Replay a completed case: worker.py --replay CASE_DIR")
    p.add_argument("--system",choices=("windows","wsl"),required=True)
    p.add_argument("--family",choices=("msvc","gcc","clang"),required=True)
    p.add_argument("--compiler",required=True)
    p.add_argument("--year",choices=("2019","2022","2026"))
    p.add_argument("--out",type=Path,required=True)
    for field in ("launches","blocks","sweeps","seed","cpu"):
        p.add_argument("--"+field,type=int,required=True)
    execute(p.parse_args())
