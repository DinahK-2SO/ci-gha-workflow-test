# OpenCV Windows test packages

Each folder is a separate test package. Copy the complete folder for the
test you want; neither needs the other folder or the repository root.

| Test | What to copy | Run from inside the copy (PowerShell 7) |
|---|---|---|
| Build and check full OpenCV revisions | [`opencv-build`](opencv-build/README.md) | `.\Run-Comparison.ps1 -WorkParent C:\ocv` |
| Compile and time the standalone DLS fill | [`dls-repro`](dls-repro/README.md) | `.\Run-DlsComparison.ps1` |
| Compare warmed DLS runtimes across Windows and WSL toolchains | [`dls-repro`](dls-repro/matrix/README.md) | `.\Run-RuntimeMatrix.ps1` |

The full-build launcher and `comparison.json` used to be at the repository
root. They now live in `opencv-build`; update any saved command or custom
config path accordingly. See each package's README for prerequisites.
