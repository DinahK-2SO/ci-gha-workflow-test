# Two-step commit comparison

Use this repository root on Windows x64 or ARM64, or copy this
**entire folder** to another location. Include `scripts` and
`source-manifest.json`; no parent directories or author-local study folders
are needed. Keep your edited `comparison.json` when updating the source folder.
An already assembled comparison folder also works.

1. Edit `comparison.json`: keep the CI `repository`, `branch_name` and
   `opencv_repository` configured
   once, then change the ordered `commits` list as needed. Use full lowercase
   40-character SHAs and unique labels. Two to eight commits are supported.
2. Run from PowerShell 7:

   ```powershell
   .\Run-Comparison.ps1
   ```

Invoking the script authorizes the listed local builds. No second confirmation
or manually chosen package/protocol/result path is required. Each invocation
creates a fresh timestamp/UUID run under `work_parent` and prints its location.
Do not invoke it again merely to replace an unfavorable or failed result.
Leave `work_parent` as `null` to use
`$env:LOCALAPPDATA\opencv-build-test\runs`, or select an absolute fixed local
directory. A missing `LOCALAPPDATA` requires an explicit path; there is no
fallback to the author's drive layout. Path checks are read-only.

Repository names in the supplied config identify the original investigation
targets, not mandatory GitHub accounts. Change them to repositories you can
access. `opencv_repository` must contain the workload's pinned OpenCV commit;
changing the repository does not change that commit or relax its guards.
Source startup requires this field explicitly, including in older source-mode
configs. Existing assembled payloads retain their frozen OpenCV identity and
reject a conflicting override.

From a clean handoff source folder, the same command automatically creates an isolated
`bootstrap-<timestamp>-<id>` directory under `work_parent`, obtains the
archives pinned by `bootstrap-lock.json` from a verified local cache (downloading
only missing entries), verifies their checksums, retrieves
exact Git sources and creates a manifest-verified runtime folder. No old
study, preinstalled Python/NumPy, author-local payload or extra manual setup
command is required. Each source-checkout invocation provisions a fresh
payload from those verified archives; an assembled folder reuses its existing
immutable payload. Build trees and results remain independent for every run.
Preparation/download time is not measured native build time.

Cache misses require access to the pinned CMake release, NuGet or Python
package files. Bootstrap still retrieves the configured Git repositories
even when all dependency archives are cached. Existing Git credentials must
already work. Failures are explicit and retained in `bootstrap.json` with
download/source logs; no alternate versions, transport fallback or automatic
retry is used. Partial payloads are rejected, not silently rebuilt.

## Automatic architecture selection

The source entry point selects **x64 or ARM64 from Windows OS architecture**,
not the shell architecture or `PROCESSOR_ARCHITECTURE`. No architecture field
or extra step is needed in `comparison.json`. It selects the matching pinned
CMake 4.1.1 and Python 3.13.14 archives, native VS2022 host/target compiler and
MSBuild paths, Python import-library/PE checks, NumPy header ABI probe, and
OpenCV output/binding checks. Other OS architectures fail explicitly.
This is native-target selection, not a cross-compilation interface.

The portable source folder works on both targets. An already assembled payload
is frozen for one architecture and is rejected on the other; use the complete
source folder there instead. Old ARM64 packages/results are not rewritten.
Architecture-specific archives have different cache identities. The same
NumPy wheel supplies **headers only**, and PyYAML supplies pure Python only;
foreign-architecture runtime extensions are never installed from those wheels.

Within one run, every selected commit uses the same configured tree, cache
hash, dependencies, helpers, toolchain and output inventory. ARM64 retains its
reference workload check. x64 requires the declared full module set and workload
options, then records/freezes its actual feature and project inventory; x64 CPU
dispatch projects need not equal ARM64 projects. Receipts identify architecture,
OS/process architecture and selected tools. Results from different architectures
cannot be pooled into one comparison or treated as an architecture-controlled
performance experiment.

Support in the launcher does not imply a successful full build on every device.
The installed toolchain check, dependency/ABI preparation and selected full
builds still must pass locally. VS2026-only installations, 32-bit Windows and
other targets are not selected by this pinned VS2022 profile.

## Dependency cache

The default is `$env:LOCALAPPDATA\opencv-build-test\cache`. Omitting
`cache_root` from `comparison.json`, or leaving it `null`, uses this default;
older config files remain valid. To use another fixed local drive, set:

```json
"cache_root": "D:\\opencv-build-test\\cache"
```

Use an absolute local path, not UNC, an environment-variable expression or a
reparse-point destination. The source/package directory cannot be the cache.
If `LOCALAPPDATA` is unavailable, an explicit path is required.

Entries are keyed by checksum algorithm, pinned digest and archive filename.
Each hit is rehashed before use. A corrupt entry causes an explicit error
with its path; it is not overwritten, redownloaded, deleted, or replaced by a
different version. Restore or remove that specific entry explicitly after
investigating it. Only a missing entry triggers a download from the locked URL.

Downloads use unique `.partial-<id>` files on the cache volume and are renamed
to the final entry only after verification. Failed partial files remain as
evidence; they are never cache hits. A later explicit invocation can retry a
missing entry without replacing its prior partial. A per-entry exclusive lock
prevents concurrent writers; a busy entry fails explicitly without downloading.

Verified archives are copied into each bootstrap directory before extraction;
run-local changes cannot modify the shared archive. `bootstrap.json` records
the resolved cache root, each hit/miss, cache path and pinned identity.
Caching archives does not reuse a build tree, result directory, or extracted
mutable tool installation. It also does not resolve network/TLS failures for
archives that have never been cached.

The script checks the payload and config, retrieves exact CI commits, creates
a self-contained run package, prepares the pinned OpenCV workload, captures
each action's actual CMake arguments without running native CMake, freezes
protocols, runs each commit once in list order, checks correctness, archives
before the next clean and validates the combined results. There is no baseline/
dev/compiler-server flag list to edit. The branch is recorded provenance:
execution always uses the specified SHA, never a floating branch tip.

## What stays fixed

The payload contains the previously qualified OpenCV
`c261e6e4b4e4bf3c1bf4e7da23193943400579ca` workload, portable CMake, native
Python development archive, NumPy compile headers, YAML, scripts and licenses.
The editable commits refer to the **CI action repository**, not OpenCV source.
Changing the OpenCV workload or toolchain versions requires separate qualification.

Windows x64/ARM64, PowerShell 7, Git with Git Bash, and Visual Studio 2022 native
matching-architecture C++ tools/SDK must already be installed. No system installer runs;
bootstrap downloads/extracts private portable inputs only.
There is no dependency on the author's checkout or old study directories.
Git access to the configured repository is needed for source verification and
retrieval. Bootstrap retrieves the pinned OpenCV commit from
`opencv_repository` in `comparison.json`. Source `profile.json` repository
slots are unresolved template values, filled from that config before the
payload is frozen. `source_transport` selects `https` (default) or `ssh`; no automatic
authentication fallback, credential setup or global Git configuration occurs.
The original immutable offline packages remain unchanged.

Only the selected action's supported `configure-and-build` build step runs,
not arbitrary GitHub workflows. Unsupported expressions, legacy experiment
inputs, multiple CMake invocations, changed command contracts or source
identities fail explicitly. A changed action that needs additional CI services
may need a separately qualified adapter, not changes to public contribution APIs.
Command capture executes the selected Bash step with a CMake interceptor in a
bounded Job; it is not a security sandbox. Select only repositories/commits
whose code you trust, as for the subsequent build itself.

## Boundaries and results

Every native build has the existing 1,800-second deadline, host/resource
guards and Job-owned cleanup. The series reserves 1,800 seconds per selected
commit. Builds run serially against one configured tree, with a clean and the
existing fixed rest before each. There are no automatic retries or resumes.
Failure stops the sequence, exports available evidence and preserves the
failed tree without another clean. An export failure is recorded separately.
Unstarted cases remain unstarted, not passed.

`<run>\summary.json` records status, config/payload identity, budgets, selected
commits and per-case locations. `<run>\results\<ordinal>-<label>\export` contains
execution/native receipts, correctness results, logs and archive hashes.
`<run>\results\functional-summary.json` is written only after all cases pass
verification. Native binaries remain in each case's local trial archive.
The config is copied into the run; editing the top-level config cannot alter
an already frozen run.

The internal legacy harness slot is named `baseline` for each independent
case; the summary's label and full SHA identify the actual selected commit.
This slot name does not imply baseline scheduling or replace its captured
command contract.

These are functional checks with diagnostic timings, not a balanced
performance study, full CI, native NumPy runtime or a proof of acceleration.
The detailed ABC interference observers are not enabled here; their earlier
coverage gaps have **not** been repaired by this interface change. No power/
security settings, publish branch or unrelated process is modified.

Optional maintainer diagnostics:

```powershell
.\Run-Comparison.ps1 -Check
.\Run-Comparison.ps1 -PrepareOnly
```

`Check` is read-only. In a source checkout it validates source inputs, config,
cache-path selection and installed tools without creating cache directories.
It explicitly reports that cache contents and network access have not been
verified. In an assembled folder it verifies the payload.
`PrepareOnly` includes automatic bootstrap when needed, creates a fresh run, performs dependency
ABI probes/configuration and captures all commands, but starts no full OpenCV
build. It is not a resumable partial run; normal invocation always creates a
new run. These switches are not additional steps for ordinary use.

## Assembling a new folder (maintainers only)

Ordinary users do not need this command: source-folder startup handles
provisioning. The following legacy assembly path is useful when a verified
local seed already exists and its dependencies should be copied instead.

From this repository root, use a verified existing self-contained package:

```powershell
.\New-ComparisonFolder.ps1 `
  -SeedPackage 'C:\path\to\verified-package' `
  -Destination 'C:\path\to\new-comparison-folder' `
  -ReceiptPath 'C:\path\to\new-assembly-receipt.json'
```

Assembly copies dependencies from the verified seed and updates local harness
scripts; it does not change the seed or any product checkout. Copy the complete
new folder to another qualified local machine. Edit only `comparison.json`;
payload and launcher hashes are checked on each invocation. Keep private raw
logs and binaries local; review evidence before publishing it.

The research-only assembler requiring the author's dated preparation receipts
and external directory layout was removed. It is not part of this standalone
interface.

## Local guard checks

The included `Test-HandoffGuards.ps1` checks package/path/identity guards,
portable configuration defaults and seed assembly without network access or
native builds. Give it fresh work and receipt paths outside this repository:

```powershell
.\Test-HandoffGuards.ps1 `
  -WorkRoot (Join-Path $env:LOCALAPPDATA 'opencv-build-test\guard-work-01') `
  -OutputPath (Join-Path $env:LOCALAPPDATA 'opencv-build-test\guard-receipt-01.json')
```

Preserve previous attempts instead of overwriting them. This is not a full
OpenCV comparison or native x64 hardware qualification.

## Updating bundled runtime sources (maintainers only)

This standalone repository owns its bundled `scripts` sources. No external
canonical source directory is required. After reviewing runtime edits, refresh
the existing declared inventory's hashes (do not use this to approve unexpected
or unreviewed content):

```powershell
$manifest = Get-Content .\source-manifest.json -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    $path = Join-Path .\scripts $file.path
    $file.bytes = (Get-Item -LiteralPath $path).Length
    $file.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 5 |
    Set-Content .\source-manifest.json -Encoding utf8NoBOM
.\Run-Comparison.ps1 -Check
```

Keep reviewed scripts and their manifest together. Runtime sources use UTF-8
without BOM and LF line endings; Git preserves their bytes. Startup verifies
the complete required inventory, lengths and hashes before preparation.
Ordinary users do not need to update the manifest or collect parent helpers.
