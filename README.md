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

On Windows ARM64 or x64, with PowerShell 7, Git/Git Bash and matching Visual
Studio 2022 C++ tools/SDK installed:

```powershell
.\Run-Comparison.ps1
```

Dependencies and Git repositories are cached across runs; Python wheels respect local pip sources.
Each test gets its own checkouts and build tree. `/nr:false` is test-only.

## 3. Read the results

The command prints the run directory, normally under
`$env:LOCALAPPDATA\opencv-build-test\runs`.
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
