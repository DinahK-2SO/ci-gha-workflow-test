"""Capture an exact action's build arguments without launching native CMake."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_contract(path, commit, prepared, builddir):
    contract = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if (contract["schema_version"] != 1 or contract["ci_commit"] != commit
            or contract["action_sha256"] != prepared["action_sha256"]
            or contract["script_sha256"] != prepared["extracted_build_step_sha256"]
            or contract["environment"] != prepared["environment"]):
        raise ValueError("Captured contract differs from the selected action")
    arguments = contract["arguments"]
    if (not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments)
            or arguments[:4] != ["--build", builddir, "--config", "Release"]
            or contract["parallel_environment"] != "8"):
        raise ValueError("Unsupported captured native build command")
    return arguments


def capture(args):
    if args.output.exists() or args.capture_root.exists():
        raise ValueError("Preserve earlier command capture")
    subprocess.run([
        sys.executable, "-B", str(Path(__file__).with_name("prepare_ci_action.py")),
        "--ci-root", str(args.ci_root), "--ci-commit", args.ci_commit,
        "--workdir", str(args.workdir), "--builddir", args.builddir,
        "--output", str(args.capture_root), "--condition", "baseline",
    ], check=True, timeout=30)
    prepared = json.loads((args.capture_root / "prepared-step.json").read_text())
    reserved = {"PATH", "RUNNER_OS", "OCV_REAL_CMAKE", "OCV_CMAKE_RECEIPT",
                "OCV_PROBE_PYTHON", "OCV_CMAKE_PROBE", "OCV_EXPECTED_BUILD_ARGUMENTS"}
    if any(key in reserved or key.startswith("OCV_CAPTURE_") for key in prepared["environment"]):
        raise ValueError("Action environment overlaps private measurement controls")
    shim = args.capture_root / "shim"
    shim.mkdir()
    (shim / "cmake").write_text(
        '#!/usr/bin/env bash\nexec "$OCV_CAPTURE_PYTHON" "$OCV_CAPTURE_SCRIPT" --record "$@"\n',
        encoding="utf-8", newline="\n")
    receipt = args.capture_root / "arguments.json"
    env = os.environ.copy()
    env.update({
        "RUNNER_OS": "Windows", "CMAKE_BUILD_PARALLEL_LEVEL": "8",
        "GITHUB_ACTION_PATH": (args.ci_root / "configure-and-build").as_posix(),
        "OCV_CAPTURE_PYTHON": Path(sys.executable).as_posix(),
        "OCV_CAPTURE_SCRIPT": Path(__file__).resolve().as_posix(),
        "OCV_CAPTURE_RECEIPT": str(receipt),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PATH": str(shim) + os.pathsep + env["PATH"],
    })
    env.update(prepared["environment"])
    with (args.capture_root / "capture.log").open("w", encoding="utf-8") as log:
        subprocess.run([str(args.bash), "--noprofile", "--norc", "-eo", "pipefail",
                        (args.capture_root / "build-step.sh").as_posix()],
                       cwd=args.workdir, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    if receipt.with_suffix(".duplicate").exists():
        raise ValueError("Selected action invoked CMake more than once")
    result = json.loads(receipt.read_text())
    result.update({
        "schema_version": 1, "ci_commit": args.ci_commit,
        "action_sha256": prepared["action_sha256"],
        "script_sha256": prepared["extracted_build_step_sha256"],
        "environment": prepared["environment"],
        "capture_helper_sha256": digest(__file__),
        "native_build_executed": False,
    })
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    validate_contract(args.output, args.ci_commit, prepared, args.builddir)
    print("Frozen native arguments without executing CMake: " + str(args.output))


def main():
    if sys.argv[1:2] == ["--record"]:
        receipt = Path(os.environ["OCV_CAPTURE_RECEIPT"])
        if receipt.exists():
            receipt.with_suffix(".duplicate").write_text("Multiple CMake invocations\n")
            raise ValueError("Multiple CMake invocations are unsupported")
        with receipt.open("x", encoding="utf-8") as stream:
            json.dump({"arguments": sys.argv[2:],
                       "parallel_environment": os.environ.get("CMAKE_BUILD_PARALLEL_LEVEL")}, stream)
        return
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ci-root", "workdir", "capture-root", "output", "bash"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--ci-commit", required=True)
    parser.add_argument("--builddir", required=True)
    capture(parser.parse_args())


if __name__ == "__main__":
    main()
