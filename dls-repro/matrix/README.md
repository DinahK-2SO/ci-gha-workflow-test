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

`launches` is an even count (2–32) of independent warmed processes, alternating
between two verified function link orders. `blocks` (1–64) is the number
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
