# Self-contained OpenCV Windows comparison

1. Edit `comparison.json` to select the CI repository, branch, ordered commit IDs
   and `opencv_repository` containing the pinned OpenCV source commit.
2. Run from PowerShell 7 in this directory:

   ```powershell
   .\Run-Comparison.ps1
   ```

The launcher automatically selects native Windows **x64 or ARM64**, obtains
checksum-verified portable dependencies, restores exact sources, and creates
independent build/results directories. PowerShell 7, Git with Git Bash, and
Visual Studio 2022 native matching-architecture C++ tools/SDK must already
be installed. No system installer or policy change is performed.

The checked-in repository names are explicit investigation selections, not
embedded credentials or required accounts. Change them in `comparison.json`
when using other forks. Repository fields accept `owner/name`, not URLs with
credentials. HTTPS is the default transport; SSH remains an explicit option.
Private repositories still require access through your own existing Git setup.

The dependency cache defaults to
`$env:LOCALAPPDATA\opencv-build-test\cache`; optional `cache_root` in the same
config selects another fixed local directory. Corrupt cached files fail
explicitly rather than being replaced silently.
NumPy/PyYAML downloads use pip's machine/user configuration and environment
variables, including `PIP_CONFIG_FILE` and `PIP_INDEX_URL`. With no source
configuration, pip uses its default PyPI index. A configured source failure
does not trigger a retry against PyPI or another mirror. Exact wheel filenames
and hashes remain locked; no packages are installed. The prepared portable
Python supplies pip unless a virtual environment is active, in which case its
Python/pip is used to preserve environment-specific settings.

With `work_parent: null`, work/results use
`$env:LOCALAPPDATA\opencv-build-test\runs`; an explicit fixed local path remains
supported. Neither default requires the author's drive layout or account.

Use `.\Run-Comparison.ps1 -Check` for read-only source/config/toolchain checks,
or `-PrepareOnly` to prepare without full OpenCV builds.
See `COMPARISON.md` for configuration, execution and evidence boundaries.

Native x64 full-build qualification remains pending. The recorded x64 ABI
verification used ARM64-hosted cross-compilation/emulation; it is not a
performance result or full native NumPy runtime qualification.

## Source provenance

This folder was copied from `DinahK-2SO/opencv-win-furnish`,
`src\msbuild\handoff`, at commit
`ef6ed0694c3b6e4cfdee005e5fa1b54f21b0e27f`.
The 17 bundled runtime sources are checked by `source-manifest.json`.
No parent-directory helpers, old payload, binary distribution or author-local
study are needed for the ordinary two-step interface.

The author-machine-specific `New-HandoffPackage.ps1` assembler is not retained.
The remaining seed-assembly/qualification helpers require explicit existing
inputs and are not needed for normal use. Runtime helpers no longer fall back
to personal study paths or an author-specific VS installation.

Generated receipts can contain local paths and machine information. Keep raw
results private and review them before sharing; this launcher never publishes
them automatically. Source edits must be accompanied by updated manifest
hashes, as described in `COMPARISON.md`.
