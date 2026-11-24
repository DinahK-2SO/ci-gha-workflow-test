# Selectable warm-runtime comparison

From `dls-repro`, edit **`runtime-matrix.jsonc`**. Each object is one environment:
set `enabled` to `true`, use `//` to comment out its one-line object, or
remove it. Block comments and trailing commas are accepted. Only VS 2022
is enabled initially. Disabled cases do not trigger compiler discovery or
start a WSL distribution. Run sequentially from PowerShell 7:

```powershell
.\Run-RuntimeMatrix.ps1 -List
.\Run-RuntimeMatrix.ps1
# Or supply a config, a specific Windows interpreter and a fresh output path:
.\Run-RuntimeMatrix.ps1 -ConfigPath .\my-cases.jsonc -Python C:\tools\python.exe -OutputDirectory C:\measurements\warm-001
```

| `command` in the config | What it runs |
|---|---|
| `["msvc","2019"]`, `["msvc","2022"]`, `["msvc","2026"]` | Selects that VS installation using `vswhere`, initializes its native C++ environment, and verifies the actual compiler version. |
| `["windows","gcc","g++.exe"]`, `["windows","clang","clang++.exe"]` | Executes that GNU-style driver on Windows. Use a full executable path if not on PATH. |
| `["wsl","Ubuntu","gcc","g++"]`, `["wsl","Ubuntu","clang","clang++"]` | Starts the named distro with `wsl.exe --exec`; both compilation and execution use Linux binaries. A guest path to the driver is also accepted. |

Commands are argument arrays, **not shell strings**. This launcher does not
install compilers or change PATH permanently. For Windows cases supply
64-bit Python 3.10+ and native x64 C++ tools (the VS adapter uses Windows
SDK `10.0.26100.0`). For WSL cases supply `python3` 3.10+ and a working
native Linux C++ toolchain, headers and linker inside that distro. No Windows
Python is required for WSL-only selections. Paths for the source package
and results must be on local drives accessible to WSL. Use an idle host;
the existing DLS guard requires 24 GiB of free host memory.

### Repetition counts

`launches` is an even count (2–32) of separate warmed processes. Each adjacent
pair uses both verified link orders. Which layout goes first is seeded and
counterbalanced (at most one extra first position when the pair count is odd).
This changes neither within-process slot order nor the number of launches
per layout. It does not sample a population of binary layouts.
`blocks` (1–64) is the number
of shuffled blocks per launch. Each block contains **AB, BA, AA and BB**
exactly once: A is original, B caches pointers; AA/BB are noise controls.
Thus each variant gets **`4 × launches × blocks` timed slots**. `sweeps`
(1–10,000) sets the work per slot: one sweep is 20 deterministic inputs at
two strides, i.e. 40 fills. Defaults of `12, 4, 500` yield 192 timed slots
per variant and 20,000 fills per slot. Keep settings equal across rows for
a side-by-side comparison; adjust them independently for a short smoke run.
`seed` (default `20261124`) reproduces the shuffled order; `cpu` (default
`-1`) selects an allowed logical CPU automatically, or set a specific index.

### Timing boundary

In each launch A and B execute in the **same process**, through a shared
call site, on the **same 40 preallocated fixtures and input/output addresses**.
The worker pins itself before allocation, reuses the selected CPU on later
launches and verifies CPU identity before and after every timed slot. One
second of common warm-up and 16 untimed target-specific sweeps precede launch
timings and individual slots, respectively. Byte-exact reference checks,
allocation, timing instrumentation for CPU/memory, output and compilation
are outside the kernel wall timer. Each program must produce the correct
output. Compiler versions, effective flags and source hashes are recorded.

These guarantees apply **within** each environment and launch: neither
virtual addresses nor physical host CPU placement are shared between Windows
and a WSL VM. The same-numbered WSL vCPU is not proof of the same physical
core. Compare B against A within a row first; this is not an isolated test
of compiler brand or OS, and does not measure whole-OpenCV builds.

### Read or replay a run

Before compilation, each case saves `protocol.json`: the fixed budget, warm-up,
metric, scope, optional practical band and no-retry rule. Set, for example,
`"practical_band_pct": 2` **before** a run if +/-2% is meaningful for that
case. Omit it for descriptive results. `faster_beyond_band` and
`slower_beyond_band` require the *entire* approximate interval strictly
beyond the chosen edge; `interval_inside_band` requires both endpoints
inside the band. Anything overlapping an edge is inconclusive at that band.
A missing interval cannot support a decision. These labels are conditional
interpretations, not tests of a universal performance threshold or proof of
bootstrap coverage. The primary effect is a paired geometric time change,
not a ratio of arithmetic means or of the displayed medians.

`matrix.txt` is the terminal comparison table; `matrix.json` includes
status and host snapshots for each selected case. If a selected tool is
missing, its row fails, the remaining selections still run, and the launcher
exits unsuccessfully. No fallback is substituted. Each `cases\<id>` contains
raw `trials.csv`, a per-pair `report.txt` and `summary.json`. Rows include
PID, logical CPU, kernel wall time, process CPU time (can quantize to zero)
and process-lifetime peak resident memory. The primary contrast is the
order-balanced percentage change in **time** for cached vs original; negative
favors cached. Intervals resample whole launches within link order. Two
launches are smoke-only: no 95% interval is reported until both layouts
have at least two launches. No outliers are removed.

```powershell
python -B .\matrix\worker.py --replay C:\measurements\warm-001\cases\vs2022
```

### Diagnosing a pilot without changing the experiment

`diagnostics.json` retains the ordered block time levels (geometric mean over
the balanced slots) and block-level code effects within every launch. The
last-half vs first-half change excludes the middle item for odd lengths;
lag-1 correlation is reported only for six or more nonconstant observations.
Across launches we compare time levels *within each layout*. Inspect these
sequences for drift, not as a test proving that warm-up finished or launches
were independent. AA/BB and link-order splits are sensitivity checks; a
change of sign between noisy point estimates does not prove a layout effect.

The optional pilot variance decomposition uses block **log effects**, not
raw fills. It reports mean within-launch sample variance `S1`, pooled
within-layout launch-mean variance `S2` (equal-size strata), and `S2-S1/blocks`.
This last value can be negative; it is a noisy planning diagnostic under a
balanced random-effects approximation, not the variance used in the interval.
`launch-costs.json` records elapsed command time and the sum of timed kernel
intervals. Their difference includes warming, conditioning, checks, startup
and other overhead; it is not a measurement of warm-up alone. Allocate future
budget at the level where variation matters. Use a separate predeclared study
to confirm; do not stop a run when the interval becomes favorable.

To inspect an archived case **without writing anything to it**, run
`python -B .\matrix\worker.py --diagnose CASE_DIR`. Receipts predating the
counterbalanced layout schedule replay with their original fixed alternation.
They have no retrospective practical-band decision. New cases check both
the frozen protocol digest and the diagnostic trace on replay.
