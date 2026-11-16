# Self-contained OpenCV Windows comparison

1. Edit `comparison.json` to select the CI repository, branch and ordered commit IDs.
2. Run from PowerShell 7 in this directory:

   ```powershell
   .\Run-Comparison.ps1
   ```

The launcher automatically selects native Windows **x64 or ARM64**, obtains
checksum-verified portable dependencies, restores exact sources, and creates
independent build/results directories. PowerShell 7, Git with Git Bash, and
Visual Studio 2022 native matching-architecture C++ tools/SDK must already
be installed. No system installer or policy change is performed.

The dependency cache defaults to
`$env:LOCALAPPDATA\opencv-build-test\cache`; optional `cache_root` in the same
config selects another fixed local directory. Corrupt cached files fail
explicitly rather than being replaced silently.

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
The 17 bundled runtime sources and `source-manifest.json` are preserved.
No parent-directory helpers, old payload, binary distribution or author-local
study are needed for the ordinary two-step interface.

Legacy maintainer assembly/qualification scripts are retained from that
folder; they are not required for normal use and may require separate study
inputs or the upstream canonical source tree.
