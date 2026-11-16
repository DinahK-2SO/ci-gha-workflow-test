import argparse
import hashlib
import json
from pathlib import Path
import re

import yaml

from ci_action_trial import assert_checkout, build_step_inputs


def main():
    parser = argparse.ArgumentParser(description="Extract the pinned CI build step without executing it")
    parser.add_argument("--ci-root", type=Path, required=True)
    parser.add_argument("--ci-commit", required=True)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--builddir", default="build")
    parser.add_argument("--output", type=Path, required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--condition", choices=("baseline", "fixed"),
                           help="Extract an unchanged baseline/fixed commit, with no public test inputs")
    selection.add_argument("--shared-cap", choices=("false", "true"),
                           help="Historical opt-in replay only")
    args = parser.parse_args()
    actual = assert_checkout(args.ci_root, args.ci_commit)
    action_path = args.ci_root / "configure-and-build" / "action.yml"
    action_bytes = action_path.read_bytes()
    action = yaml.load(action_bytes.decode("utf-8"), Loader=yaml.BaseLoader)
    steps = [step for step in action["runs"]["steps"] if "::group::Build" in step.get("run", "")]
    if len(steps) != 1:
        raise ValueError("Expected exactly one build step")
    if args.condition and {"msbuild_shared_cap", "msbuild_compiler_jobs"} & action["inputs"].keys():
        raise ValueError("Commit comparison cannot use a public experimental scheduling input")
    if args.shared_cap == "true" and "msbuild_shared_cap" not in action["inputs"]:
        raise ValueError("This CI commit has no shared-cap input")
    inputs = build_step_inputs(args.workdir, args.builddir, args.shared_cap)

    def expand(value):
        result = re.sub(r"\$\{\{\s*inputs\.([a-z_]+)\s*\}\}", lambda match: inputs[match.group(1)], value)
        if "${{" in result:
            raise ValueError("Unsupported GitHub expression in selected build step")
        return result

    script = expand(steps[0]["run"])
    args.output.mkdir()
    script_path = args.output / "build-step.sh"
    script_path.write_text(script, encoding="utf-8", newline="\n")
    record = {
        "ci_commit": actual,
        "comparison_axis": "baseline_vs_fixed_commit" if args.condition else "historical_optin",
        "condition": args.condition,
        "action_sha256": hashlib.sha256(action_bytes).hexdigest(),
        "extracted_build_step_sha256": hashlib.sha256(script_path.read_bytes()).hexdigest(),
        "inputs": inputs,
        "environment": {name: expand(value) for name, value in steps[0].get("env", {}).items()},
        "preparer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "yaml_version": yaml.__version__,
        "workload_executed": False,
    }
    (args.output / "prepared-step.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print("Prepared exact build step; no workload executed: " + str(args.output))


if __name__ == "__main__":
    main()
