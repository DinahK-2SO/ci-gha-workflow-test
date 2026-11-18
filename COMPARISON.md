# Independent source comparisons

Use this repository root on Windows x64 or ARM64, or copy this
**entire folder** to another location. Include `scripts` and
`source-manifest.json`; no parent directories or author-local study folders
are needed. Keep your edited `comparison.json` when updating the source folder.
An already assembled comparison folder also works.

1. Edit the JSON array in `comparison.json`. Each object requires its own
   `opencv-repo`, `opencv-branch`, `opencv-commit`, `ci-gha-repo`,
   `ci-gha-branch` and `ci-gha-commit`. Repositories use `owner/name`;
   commits use full lowercase 40-character SHAs. One to eight cases are supported.
   Optional labels must be unique; omitted labels become `case-<ordinal>`.
   Reusing either commit across cases is allowed.
2. Run from PowerShell 7:

   ```powershell
   .\Run-Comparison.ps1
   ```

Invoking the script authorizes the listed local builds. No second confirmation
or manually chosen package/protocol/result path is required. Each invocation
creates a fresh compact UUID-named run and prints its location.
Timestamps remain in the receipts. Short run names leave room for MSBuild's
long sample-project intermediate filenames without changing Windows policies.
Generated project paths are checked after configuration, before clean/build;
an overly long custom parent receives an explicit request to shorten
`-WorkParent` rather than failing later inside MSBuild.
Do not invoke it again merely to replace an unfavorable or failed result.
The default is `$env:LOCALAPPDATA\opencv-build-test\runs`; pass `-WorkParent`
to select an absolute fixed local directory. A missing `LOCALAPPDATA` requires an explicit path; there is no
fallback to the author's drive layout. Path checks are read-only.

Repository names in the supplied config identify the original investigation
targets, not mandatory GitHub accounts. Change them to repositories you can
access. Each repository must contain its case's selected commit, and each
named branch must exist in the source cache or be fetched successfully.
Recorded branch heads are cached snapshots, not live upstream checks, and are
never substituted for requested commits. The old object-with-`commits` config is rejected: migrate
each entry to the six explicit source fields in the array.

From a clean handoff source folder, the same command automatically creates an isolated
`bootstrap-<timestamp>-<id>` directory under the work parent, obtains the
archives pinned by `bootstrap-lock.json` from a verified local cache (downloading
only missing entries), verifies their checksums, retrieves
exact Git sources and creates a manifest-verified runtime folder. No old
study, preinstalled Python/NumPy, author-local payload or extra manual setup
command is required. Each source-checkout invocation provisions a fresh
payload from those verified archives; an assembled folder reuses its existing
immutable payload. Sources are retrieved into a new run-local package, never
rewritten in the seed. Every case has independent checkouts, configuration,
build tree and results, even when two cases select the same commits.
Preparation/download time is not measured native build time.

### Trusted-input fast mode (default)

`Run-Comparison.ps1` defaults to `-RepoIntegrityChecks:$false`. This assumes
the source folder, assembled payload and dependency/Git caches are trusted and
are not edited outside the cache's normal Git fetch/update operations.
It skips repeated runtime-source and launcher digest comparisons, package
inventory/digest verification, cached dependency checksum comparisons,
Git `fsck --full`, local-fetch object checking and explicit `git bundle verify`.
This applies after Git cache updates as well as on cache hits. New dependency
downloads are still checked against their pinned digest before cache publication.
Git's own required decoding/connectivity checks are not disabled.

Restore the original integrity checks with:

```powershell
.\Run-Comparison.ps1 -RepoIntegrityChecks:$true
```

The setting is forwarded through the fresh-process launcher, bootstrap and
per-case preparation. Receipts record its inverse as `skip_integrity_checks`.
Standalone `Start-Study.ps1` and support helpers retain strict defaults;
the comparison launcher explicitly passes its selection.
Fast mode does not remove copies, extraction, local Git transfers or bundle
creation. Hashes needed to create manifests and provenance/evidence records
are still computed. Locks, path/archive safety, config/commit/origin/architecture
checks, native builds, C++ checks, binding DLL loading and final result
validation remain enabled. Corruption that only an integrity scan would detect
may therefore go unnoticed in fast mode.

Cache misses require access to the pinned CMake release, NuGet or configured
Python package sources. Git access is needed only for a missing repository,
branch or commit; complete source-cache hits work offline. Existing Git
credentials must already work for misses. Failures are explicit and retained in `bootstrap.json` with
download/source logs; no alternate versions, transport fallback or automatic
retry is used. Partial payloads are rejected, not silently rebuilt.

The terminal shows named source stages and per-case progress such as
`[A 1/3] Restore sources and configure build ...` followed by `OK` or `FAILED`.
Successful low-level Git commands stay quiet. Git operations and case controllers
that are still running after 60 seconds show their diagnostic log path, then
repeat at most every two minutes. This means "still running", not proof of a
hang. Failures immediately identify the failed stage and its log.
Failed or timed-out Git commands also print up to six trailing log lines
(at most 500 characters per line) and include them in the error receipt, so
transport or authentication errors are visible without opening the log.
The complete log is retained; this does not add retries or transport fallback.
Detailed case-controller output stays in `prepare.log`, `build.log` and
`export.log` beside each case's export directory; aggregate checks use
`results\validation.log`. Run and final-summary paths are still printed.
After all cases pass aggregate validation, an aligned English table (without
grid lines) shows the case, abbreviated OpenCV and builder commits, single-build
seconds, pre-build CPU samples and `PreBld CPU mean (%)`, C++ checks and binding DLL load result.
An empty line separates the table from its explanatory notes. The launcher
prints local start and finish timestamps, including the UTC offset, once per
invocation across bootstrap and fresh-process handoffs. The finish timestamp
also appears on failure when PowerShell can execute cleanup.
Values come from that run's verified results and archived execution records,
not the current editable configuration. CPU readings describe whole-machine
usage before each build, not average usage during the build.
Host guards compare the latest System log Kernel-General event 12 record
(machine and record ID) to identify the boot session. WMI `LastBootUpTime`
remains diagnostic only: it can drift with system time adjustments and is
not an exact boot-identity key. The System log must be readable and retain
the latest startup event; query failures are explicit, not silently ignored.
OS version, AC power, battery saver, power scheme and configured AC power mode
checks remain enforced. A mismatch identifies the field and its expected/actual
values. Old snapshots without a boot-session ID require a newly prepared study;
failed results and frozen protocols are not rewritten or automatically retried.
Controller observation adds no outer deadline or changes to native build timing.
The full-history OpenCV fetch and bundle creation each have a 30-minute deadline;
other Git commands retain a five-minute deadline. Git exit codes and timeout
results are saved beside each log in `.log.json`. Bootstrap prints its final
status and receipt path. An interrupted operation is recorded as `interrupted`,
not left marked `preparing`, when PowerShell can execute its cleanup block.
Forced process termination or power loss cannot guarantee receipt finalization.
If the calling PowerShell session already loaded the runtime helper, the entry
point uses a fresh child process and propagates its exit status. Updating or
rerunning the folder therefore does not silently reuse an older loaded helper.

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

Within one run, cases share pinned dependency versions, helpers and toolchain,
not a configured tree or cache hash. The reference OpenCV commit retains its
architecture-specific workload guard. Other commits must retain the required
full-build options and core, imgproc, Python and test-support modules; their
actual features, modules and projects are recorded independently. Source
version and DLL names are derived from each checked-out OpenCV version header.
Output inventories may differ between source versions and are not represented
as identical workloads. Receipts identify architecture,
OS/process architecture and selected tools. Results from different architectures
cannot be pooled into one comparison or treated as an architecture-controlled
performance experiment.

Support in the launcher does not imply a successful full build on every device.
The installed toolchain check, dependency/ABI preparation and selected full
builds still must pass locally. VS2026-only installations, 32-bit Windows and
other targets are not selected by this pinned VS2022 profile.

## Cache location

The default is `$env:LOCALAPPDATA\opencv-build-test\cache`.
To use another fixed local drive, pass a command-line option:

```powershell
.\Run-Comparison.ps1 -CacheRoot 'D:\opencv-build-test\cache'
```

Use an absolute local path, not UNC, an environment-variable expression or a
reparse-point destination. The source/package directory cannot be the cache.
If `LOCALAPPDATA` is unavailable, an explicit path is required.

### Git source cache

OpenCV and CI selections use the same `Get-ComparisonCachedGitSource` helper.
Repositories persist under `<CacheRoot>\git\<repository-id>.git` as bare
repositories, separate from dependency archives and per-run worktrees.
The repository ID is SHA256 of the lowercase `owner/name`; hashed directory
names avoid Windows reserved names and path ambiguity. The raw origin URL
identifies each repository. Credentials remain in the existing Git credential
configuration, not in generated cache URLs.

On a hit, the helper verifies the origin, complete bare-repository layout and
object integrity with `git fsck --full` when integrity checks are enabled,
then fetches the selected commit locally into the run's
independent repository. No remote request, shared worktree, object alternate
or build output is used. Branch snapshots are stored under case-sensitive hashed
refs, and selected commits are pinned so a later branch update cannot discard
them. A cache miss creates the repository if needed, fetches the requested
branch, and fetches the exact commit separately only if that branch did not
provide it. Missing commits refresh their branch snapshot; an existing
branch/commit hit does not poll upstream. The comparison config still requires
full commit SHAs, even though the helper can also resolve a cached branch.

An exclusive per-repository lock covers verification, updates and local source
transfer. A busy cache fails explicitly instead of racing another invocation.
Wrong origins and shallow/shared-object caches fail in either mode.
Corruption detected with integrity checks enabled fails without
deleting, replacing or silently repairing the cache. Failed transfers retain
logs and valid prior cached refs; there is no automatic retry or transport
fallback. Initial large downloads can still fail if the connection drops.

Each run builds its own standalone bundles (explicitly verified when integrity
checks are enabled), independent checkouts
and build directories. `source-cache.json` records resolved repository IDs,
paths, branch snapshots and hit/fetch outcomes for that bootstrap or run.
Deleting a run does not delete the shared cache. Old run-local repositories are
not automatically imported; the shared cache is populated on first successful
acquisition.

### Dependency cache

Entries are keyed by checksum algorithm, pinned digest and archive filename.
With integrity checks enabled, each hit is rehashed before use. A corrupt entry causes an explicit error
with its path; it is not overwritten, redownloaded, deleted, or replaced by a
different version. Restore or remove that specific entry explicitly after
investigating it. Only a missing entry triggers acquisition.

NumPy and PyYAML use `pip download`, not hardcoded public wheel URLs. Pip reads
its normal machine/user configuration and environment variables, including
`PIP_CONFIG_FILE`, `PIP_INDEX_URL`, additional indexes, `no-index`, local links,
proxy and certificate settings. No index or trusted host is injected by this
launcher. If there is no source configuration, pip's default is PyPI; a
configured source failure never causes the launcher to try PyPI instead.
Explicit additional indexes remain part of the user's pip configuration.
The portable Python archive is verified and extracted before wheel acquisition
to supply pip without a system installation. An active `VIRTUAL_ENV` instead
selects its Python/pip, preserving site configuration; an invalid environment
or missing pip fails explicitly rather than silently selecting another setup.

Only the exact locked CPython wheel filename/version/tags and SHA256 are
accepted. Dependencies and source builds are disabled, and these wheels are
downloaded, not installed. Pip's version check and automatic retries are
disabled. The checksum-keyed archive cache remains authoritative.
Pip diagnostics and pinned requirements are retained beside partial downloads
in `pip-<id>` directories under the digest's cache directory. Short working
directory names avoid adding the wheel filename twice to pip's paths on Windows.
Treat these logs as private: configured feeds
and authentication tooling can emit account information or sensitive URLs.
Source addresses/credentials are not copied from pip configuration into
bootstrap receipts. CMake and the Python interpreter's NuGet archive still use
their locked URLs; pip configuration does not configure NuGet access. On
restricted hosts, those archives also require an approved acquisition path.

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

For maintainer validation, the existing handoff guards can also exercise real
pip against local fixture indexes (no network or OpenCV builds). Supply an
existing Python with pip, such as a previously prepared portable interpreter:

```powershell
$testRoot = Join-Path $env:TEMP ('opencv-pip-guards-' + [guid]::NewGuid().ToString('N'))
.\Test-HandoffGuards.ps1 -WorkRoot $testRoot -OutputPath "$testRoot.json" `
    -PipPython 'C:\path\to\python.exe'
```

The optional pip cases cover configured indexes, environment overrides, active
virtual-environment configuration, failure without a public fallback, pinned
hash rejection, and cache reuse/corruption. Default PyPI selection is inspected
without making a network request. Fixture environment changes are process-local
and restored when the tests finish.

The script checks the payload and config, retrieves exact OpenCV and CI commits, creates
case-specific packages, prepares each selected OpenCV workload, captures
each action's actual CMake arguments without running native CMake, freezes
protocols, runs each case once in list order, checks correctness, archives
before preparing the next case and validates the combined results. There is no baseline/
dev/compiler-server flag list to edit. The branch is recorded provenance:
execution always uses the specified SHA, never a floating branch tip.

## What stays fixed

The local test harness explicitly passes `/nr:false` to every pre-build clean
and measured MSBuild build, uniformly for all selected commits. This is a
test-only policy: public action inputs, action files and checked-out commits
are not changed. The existing CMake measurement adapter first checks the
original captured arguments, then adds the native switch after `--`. It
preserves other options, normalizes an existing false node-reuse switch, and
rejects an explicit conflicting node-reuse setting instead of silently
overriding it.

Frozen protocols, execution/trial records and the functional summary declare
`test_build_policy.msbuild_node_reuse: false`. `cmake-invocation.json` keeps
`arguments` as the original action arguments and records `effective_arguments`
as those actually passed to native CMake. Result validation checks both and
the clean command. Earlier runs lacking this policy remain historical evidence;
they are not relabeled or pooled with the `/nr:false` runs.

The payload contains the selected OpenCV and CI Git bundles, portable CMake,
native Python development archive, NumPy compile headers, YAML, scripts and
licenses. Dependency versions and configure options remain pinned; both
OpenCV and CI repository/branch/commit selections are case-specific.

Windows x64/ARM64, PowerShell 7, Git with Git Bash, and Visual Studio 2022 native
matching-architecture C++ tools/SDK must already be installed. No system installer runs;
bootstrap downloads/extracts private portable inputs only.
There is no dependency on the author's checkout or old study directories.
Git access to the configured repository is needed for source verification and
retrieval. Source `profile.json` is a workload/tool template; its source slots
are replaced by each array entry before its package is frozen.
`-SourceTransport https` (default) or `-SourceTransport ssh` selects transport; no automatic
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
case. Builds run serially against separate configured trees, with a clean and the
existing fixed rest before each. There are no automatic retries or resumes.
Failure stops the sequence, exports available evidence and preserves the
failed tree without another clean. An export failure is recorded separately.
Unstarted cases remain unstarted, not passed.

`<run>\summary.json` records status, config/payload identity, budgets, selected
source selections and per-case locations. `<run>\results\<ordinal>-<label>\export` contains
execution/native receipts, correctness results, logs and archive hashes.
`<run>\results\functional-summary.json` is written only after all cases pass
verification. Native binaries remain in each case's local trial archive.
The config is copied into the run; editing the top-level config cannot alter
an already frozen run.

The internal harness slot is named `baseline` for each independent
case; the summary's label and both source identities identify the selected code.
This slot name does not imply baseline scheduling or replace its captured
command contract.

These are functional checks with diagnostic timings, not a balanced
performance study, full CI, native NumPy runtime or a proof of acceleration.
The detailed ABC interference observers are not enabled here; their earlier
coverage gaps have **not** been repaired by this interface change. No power/
security settings, publish branch or unrelated process is modified.

The selected CI action must expose the supported `configure-and-build`
build step. OpenCV must support the pinned toolchain/configuration, Python
bindings and the ten selected C++ checks: four matrix checks, five threshold
checks and `Calib3d_SolvePnP.accuracy`. The pose check runs in the geometry
test executable on OpenCV 5.x and the calib3d executable on 4.x. Incompatible historical versions
fail explicitly; changing the commit does not silently skip missing tests.

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
