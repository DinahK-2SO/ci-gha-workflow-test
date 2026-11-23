# OpenCV Windows build comparison

## 1. Edit `comparison.json`

Each object is one independent test. Replace its six source values:

```json
[
  {
    "label": "my-test",
    "opencv-repo": "<owner>/<opencv-repository>",
    "opencv-branch": "<branch>",
    "opencv-commit": "<full lowercase 40-character SHA>",
    "ci-gha-repo": "<owner>/<ci-workflow-repository>",
    "ci-gha-branch": "<branch>",
    "ci-gha-commit": "<full lowercase 40-character SHA>"
  }
]
```

Add/remove objects as needed (1-8 tests, in list order). `label` is optional;
if provided, keep it unique. Each test builds its selected OpenCV commit using
its selected CI action. Branches record provenance; commits select the code.

## 2. Run

On Windows, install PowerShell 7, Git/Git Bash and the matching native C++
tools/SDK (Visual Studio 2019 on x64, 2022 on ARM64). Pass `-WorkParent` with a short,
writable local path outside the checkout, such as `C:\ocv`. Longer paths can
push generated MSBuild intermediate file names past the 259-character limit,
stopping the run before compilation.

```powershell
.\Run-Comparison.ps1 -WorkParent C:\ocv
```

Dependencies and Git repositories are cached across runs; Python wheels respect local pip sources.
Each test gets its own checkouts and build tree. `/nr:false` is test-only.

By default, trusted-input mode skips repeated input integrity checks, assuming
the source/package/cache files are not edited outside normal Git cache updates.
`RepoIntegrityChecks` defaults to false. Use
`.\Run-Comparison.ps1 -WorkParent C:\ocv -RepoIntegrityChecks:$true` to enable full checking.
New dependency downloads, source/architecture identity checks and all build-result
validation remain checked. Copies and manifest/evidence hashing are not skipped.

## 3. Read the results

The command prints the run directory under the specified `-WorkParent`
(for example, `C:\ocv\run-<id>`).
`summary.json` records progress/errors; `results\functional-summary.json`
contains verified results after all tests pass, shaped like this
(placeholders, not measurements):

```json
{
  "status": "configured_comparison_passed",
  "conditions": [
    {
      "label": "<test label>",
      "status": "functional_build_passed",
      "native_wall_seconds": "<build seconds>",
      "selected_cpp_checks_passed": "<check count>"
    }
  ]
}
```

Per-test logs and receipts are in `results\<ordinal>-<label>\export`.
Timings are diagnostic, not proof of a speedup. See `COMPARISON.md` for limits
and optional settings.
