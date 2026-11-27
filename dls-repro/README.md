# Paired DLS fill experiment for native Windows

**To compare steady-state runtime across Windows and WSL**, edit
[`runtime-matrix.jsonc`](runtime-matrix.jsonc) and run `.\Run-RuntimeMatrix.ps1`.
Choose any subset of MSVC 2019/2022/2026, Windows GCC/Clang or WSL GCC/Clang.
See [matrix usage, commands and repeat counts](matrix/README.md). The
older MSVC compile/runtime comparison and fixed GCC order probe remain separate.

Copy **this directory alone** to a local drive. It compares two versions of
the same 1,968 assignments: `original.cpp` accesses matrix/vector elements
through inline accessors; `cached.cpp` caches pointers and row stride. No
OpenCV checkout or libraries, Git, Python, CMake, downloads or sibling
build-comparison files are required for the MSVC comparison. This is an extracted fill kernel, not
the complete DLS solver or proof of a compiler bug.

For the separate **GCC runtime order probe** (fresh vs warm processes,
randomized run order, same-function controls and confidence intervals), see
[order-probe](order-probe/README.md). It uses Python and a pinned native
GCC toolchain; it does not replace or run the MSVC comparison below.

## Run

Use PowerShell 7, native x64 or ARM64 Windows, a VS 2022 installation with
matching native C++ tools, and Windows SDK `10.0.26100.0`. The **full build
harness** in the sibling `opencv-build` folder has different toolchain requirements.
Use an idle machine with at least 24 GiB of free memory. The runner refuses
competing compilers, MSBuild nodes and OpenCV tests; do not stop other users'
processes. It changes no machine settings. Results use a fresh directory
under `%TEMP%` unless explicitly provided.

```powershell
.\Run-DlsComparison.ps1
# Or choose a config, installed edition and NEW results directory:
.\Run-DlsComparison.ps1 -ConfigPath .\config.json `
  -VisualStudio 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise' `
  -OutputDirectory C:\measurements\dls-001
```

| Config key | Applies to each variant |
|---|---|
| `compile_pairs` | Measured compilations (1-12; default 2). |
| `runtime_pairs` | Measured execution batches (1-40; default 4). |
| `warmup_pairs_per_phase` | Extra excluded pairs before each phase (1-4; default 1). |
| `sweeps_per_runtime_trial` | Timed passes over **20 deterministic input sets x 2 row strides** (1-100000; default 500). |

Each pair always runs both variants the same number of times. First position
alternates AB/BA. Prefer even measured counts to balance order. Results
from different toolchains, hosts or sweep counts should not be pooled.

## What the numbers mean

- **Compile:** time to compile one translation unit to a fresh object, with
  identical Release flags, compiler process environment, directory and
  output name. The source is the only intended difference. SDK setup,
  hashing, host snapshots, copying the objects and linking are outside this
  interval. Compiler and source hashes are checked before and after.
- **Runtime:** one executable contains both separately compiled objects,
  without link-time optimization. Each sample is a fresh process using the
  same ordered input sets, matrix initialization and strides (120 and 127).
  The first sweep pre-touches the fixtures and is checked outside the timer.
  `ns_per_fill` measures only the repeated sweep loop, including common loop
  and dispatch overhead, not allocation, launch, checking or printing. Full
  buffers, padding, guards, input bytes and matrix view are checked against
  an independent table before and after the timed sweeps.
- **Telemetry:** `report.txt` mirrors the terminal. `PAIR` shows original,
  cached and their signed difference. `TRIAL` contains the exact command,
  times, two host snapshots, job CPU (user/kernel), peak job memory, page
  faults, I/O bytes and operation counts, launcher PID, process count,
  timeout/exit and object size/hash or kernel result. The CPU busy percentage
  is system time over the command interval (Windows processor-group scope
  on large machines), not the program's CPU share. Clock and free-memory
  snapshots are **not** continuous samples; peak job memory is not RSS.
  `wall_s`/process-tree CPU include the common `cmd` launcher and all child
  work up to command exit, including runtime setup and checks; CPU seconds
  are not wall seconds. Windows can still count compiler helpers in the job
  at that instant; `ActiveAtCommandExit` records this, and closing the private
  job cleans up any remaining descendants before the next command.
- **Summary:** warm-ups and setup are excluded. For wall, CPU, peak job memory
  and runtime ns/fill, `SUMMARY` gives count, mean, median, min, max and
  sample standard deviation (null for one observation), separately for each
  variant and for the within-pair `cached - original` difference. Negative
  time differences favor cached. Background load, power/frequency changes
  and caches still matter. No outlier removal, automatic retry, or
  performance-significance claim.

`result.json` retains machine-readable records; `*.log` retains exact command
output. An error fails the run instead of treating missing samples as zero.
Results include local paths and environment diagnostics; review before sharing.
Run `.\Test-Experiment.ps1` for logic-only tests, or give it `-ResultDirectory`
to additionally validate a completed run.

**Source and license:** `seed\provenance.json` identifies the OpenCV 4.10.0
source commit/function and hashes for the two generated translation units,
reference table and Apache 2.0 license. `seed\LICENSE-OpenCV.txt` is included.
The tool initialization and process-accounting helpers were adapted from
`DinahK-2SO/opencv-win-furnish` (`9034a97`); the checker now shares the same
fixtures between correctness checks and kernel measurements. Allocation,
transpose and the surrounding historical solver are deliberately absent.
