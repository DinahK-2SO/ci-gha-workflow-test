# Is the cached fill faster, or did it run second?

This **runtime** test compares the two GCC-compiled DLS fill functions in
`..\seed`. It is independent of the MSVC benchmark and the full OpenCV build.
Copy the entire `dls-repro` directory, **not just `order-probe`**. No
research checkout, prior receipt, Python packages, OpenCV or network access
is needed to run it once the following tools are available.

## Run on native Windows x64

Use PowerShell 7, native 64-bit Python 3.10+ and the WinLibs GCC 16.2.0
x64 UCRT `mingw64\bin` directory specified in `toolchain.lock.json`. Use an
idle machine with at least 24 GiB free RAM (the shared DLS host guard).
From `dls-repro`, for example:

```powershell
.\Run-GccOrderProbe.ps1 -CompilerBin C:\tools\winlibs\mingw64\bin
```

Use `-Python C:\path\to\python.exe` if the default `python` is not the
desired interpreter. `-OutputDirectory C:\measurements\order-001` selects
a **new** directory; by default the launcher prints a unique path under
`%TEMP%`. The launcher never downloads tools or changes machine settings.
If you need the toolchain, download the ZIP from the
[pinned WinLibs release](https://github.com/brechtsanders/winlibs_mingw/releases/tag/16.2.0posix-23.1.3-14.0.0-ucrt-r3),
check its SHA-256 against `toolchain.lock.json` before extracting, and pass
the extracted `mingw64\bin` path. The probe also checks the driver and
binutils identities. WPR is optional and only lists available counters;
it does not start a trace.

## Protocol and outputs

`A` = original accessor code; `B` = cached pointers. Each block contains AB,
BA, AA and BB, shuffled with a fixed seed. AA and BB measure the effect of
position without changing the code. Each timed slot runs 500 sweeps over
20 deterministic inputs at 2 strides (20,000 fills). Correctness checks,
allocation and report writing are outside the timer.

| Arm | What is controlled | Observations |
|---|---|---:|
| Fresh (secondary) | One original checker process per slot, inheriting the same single-CPU affinity | 8 blocks, 64 slots |
| Warm (primary) | Shared addresses and call site; one-second common warm-up and 16 untimed target sweeps per slot; two alternating, verified link layouts | 12 launches, 4 blocks each, 384 slots |

These constants intentionally match the original experiment, **not** the
MSVC `config.json`. In `report.txt` and on the terminal, read the warm
`cached_vs_original` estimate first. A negative value means B took less
time. Compare it with the `slot2_vs_slot1` estimates, including AA and BB.
The intervals resample whole warm launches within link layout (whole blocks
for fresh), not the many fills within a slot. The interval speaks to this
host and workload, not all OpenCV use or the cause of a timing difference.

The run writes all 448 ordered slots to `trials.csv`, all paired estimates
to `summary.json`, and source/tool identities, affinity, power scheme and
realized link addresses to `meta.json`. `build` contains the objects,
disassemblies and checkers. A nonzero exit or missing final report is not
a completed run; do not pool partial data.

Replay or test the analysis without the compiler, from `dls-repro`:

```powershell
python -B .\order-probe\analyze.py C:\measurements\order-001\trials.csv
python -B -m unittest discover -s .\order-probe -p "test_*.py"
```

Ported from the [November 24 experiment](https://github.com/DinahK-2SO/opencv-win-furnish/tree/cecfefefd6fa47abb02a1535bc8f5b8bc28706b3/src/results/2026-1124/gcc-order-probe).
