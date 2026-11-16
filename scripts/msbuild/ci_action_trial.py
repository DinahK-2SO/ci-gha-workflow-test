import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from cmake_probe import TEST_BUILD_POLICY, test_build_arguments

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], text=True, encoding="utf-8"
    ).strip()


def assert_checkout(root, expected):
    if not re.fullmatch(r"[a-f0-9]{40}", expected):
        raise ValueError("A full expected commit SHA is required")
    actual = git(root, "rev-parse", "HEAD")
    if actual != expected or git(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Checkout identity or tracked contents differ: " + str(root))
    return actual


def build_step_inputs(workdir, builddir, legacy_shared_cap=None):
    inputs = {
        "workdir": workdir.as_posix(), "builddir": builddir,
        "generator": "Visual Studio 17 2022",
    }
    if legacy_shared_cap is not None:
        inputs.update({
            "msbuild_shared_cap": legacy_shared_cap,
            "msbuild_compiler_jobs": "8" if legacy_shared_cap == "true" else "",
        })
    return inputs


def read_cmake_cache(builddir):
    values = {}
    for line in (builddir / "CMakeCache.txt").read_text(encoding="utf-8").splitlines():
        if "=" in line and ":" in line.partition("=")[0] and not line.startswith(("#", "//")):
            key, _, value = line.partition("=")
            values[key.partition(":")[0]] = value
    return values


def check_native_python(builddir, architecture="ARM64"):
    values = read_cmake_cache(builddir)
    machines_by_architecture = {"ARM64": 0xAA64, "x64": 0x8664}
    if architecture not in machines_by_architecture:
        raise ValueError("Unsupported native build architecture: " + architecture)
    if values.get("CMAKE_GENERATOR_PLATFORM") != architecture:
        raise ValueError(f"This frozen local study requires a {architecture} build tree")
    if values.get("BUILD_opencv_python3") != "ON":
        raise ValueError("This frozen base-build study requires Python bindings to remain enabled")
    if "opencv_python3" not in values.get("OPENCV_MODULES_BUILD", "").split(";"):
        raise ValueError("Python bindings were requested but excluded from the effective module set")
    if not (Path(values["PYTHON3_NUMPY_INCLUDE_DIRS"]) / "numpy" / "arrayobject.h").is_file():
        raise ValueError("The configured NumPy compile inputs are missing")
    library = Path(values["PYTHON3_LIBRARY"])
    version = ".".join(values["CMAKE_CACHE_" + part + "_VERSION"] for part in ("MAJOR", "MINOR", "PATCH"))
    compiler_info = (builddir / "CMakeFiles" / version / "CMakeCXXCompiler.cmake").read_text(encoding="utf-8")
    match = re.search(r'set\(CMAKE_CXX_COMPILER "([^"]+)"\)', compiler_info)
    if match is None:
        raise ValueError("Cannot identify the configured compiler's binary inspector")
    dumpbin = Path(match.group(1)).with_name("dumpbin.exe")
    headers = subprocess.check_output(
        [str(dumpbin), "/nologo", "/headers", str(library)], timeout=30
    ).decode("utf-8", errors="replace")
    machines = {int(value, 16) for value in re.findall(r"(?m)^\s*([0-9a-fA-F]{4}) machine\b", headers)}
    if machines != {machines_by_architecture[architecture]}:
        raise ValueError(f"{architecture} Python bindings have incompatible import-library machines: "
                         + repr([hex(machine) for machine in sorted(machines)]))
    if "windowsapps" in values.get("PYTHON3_EXECUTABLE", "").lower():
        raise ValueError("The configured packaged Python launcher has not passed this study's process-ownership guard")
    return {"python_bindings": True, "library_sha256": sha256(library),
            "architecture": architecture, "machine": hex(machines_by_architecture[architecture])}


def check_configured_workload(builddir, expected, reference_build=None):
    values = read_cmake_cache(builddir)
    actual_options = {key: val for key, val in values.items() if key.startswith(("BUILD_", "WITH_"))}
    if "required_options" in expected:
        drift = {key: [val, values.get(key)] for key, val in expected["required_options"].items()
                 if values.get(key) != val}
    else:
        keys = expected["feature_options"].keys() | actual_options.keys()
        drift = {key: [expected["feature_options"].get(key), actual_options.get(key)] for key in sorted(keys)
                 if expected["feature_options"].get(key) != actual_options.get(key)}
    if drift:
        raise ValueError("Base-build feature options drifted: " + repr(drift))
    if expected["modules"] != values["OPENCV_MODULES_BUILD"].split(";"):
        raise ValueError("The effective OpenCV module set changed")

    def projects(root):
        text = (root / "OpenCV.sln").read_text(encoding="utf-8-sig")
        return sorted(re.findall(r'^Project\("[^"]+"\) = "([^"]+)", "[^"]+\.vcxproj"', text, re.M))

    after = projects(builddir)
    before = expected.get("projects")
    if before is None and "required_options" not in expected:
        before = projects(reference_build)
    if not after or (before is not None and before != after):
        raise ValueError("Generated build project set changed")
    return {
        "feature_option_count": len(actual_options), "feature_options": actual_options,
        "feature_options_unchanged": "required_options" not in expected,
        "workload_policy": expected.get("inventory_policy", "Exact reference feature/module/project inventory"),
        "modules": values["OPENCV_MODULES_BUILD"].split(";"),
        "projects": after, "project_count": len(after),
        "cpu_baseline": values.get("CPU_BASELINE", ""), "cpu_dispatch": values.get("CPU_DISPATCH", ""),
        "numpy_configure_version": values.get("PYTHON3_NUMPY_VERSION", ""),
        "python_version": values["PYTHON3_VERSION_STRING"],
    }


def main():
    parser = argparse.ArgumentParser(description="Run the exact selected CI build step locally with pinned provenance")
    parser.add_argument("--ci-root", type=Path, required=True)
    parser.add_argument("--ci-commit", required=True)
    parser.add_argument("--ci-repository", required=True)
    parser.add_argument("--ci-branch", required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-repository", required=True)
    parser.add_argument("--source-branch", required=True)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--builddir", default="build")
    parser.add_argument("--architecture", choices=("ARM64", "x64"), default="ARM64")
    parser.add_argument("--cache-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cmake", type=Path, required=True)
    parser.add_argument("--bash", type=Path, required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--condition", choices=("baseline", "fixed"),
                           help="Compare unmodified commits without injecting scheduling inputs")
    selection.add_argument("--shared-cap", choices=("false", "true"),
                           help="Historical opt-in replay only")
    parser.add_argument("--label", required=True)
    parser.add_argument("--build-contract", type=Path,
                        help="Private captured command contract for an arbitrary selected CI commit")
    parser.add_argument("--compiler-jobs", type=int, default=8,
                        help="Frozen expected shared compiler budget; does not override the action")
    parser.add_argument("--role", choices=("excluded_pilot", "functional_qualification"), default="excluded_pilot")
    args = parser.parse_args()
    if args.compiler_jobs < 1:
        parser.error("--compiler-jobs must be positive")
    if args.shared_cap is not None and args.compiler_jobs != 8:
        parser.error("Historical opt-in replay requires eight compiler slots")
    if args.build_contract and args.shared_cap is not None:
        parser.error("Captured contracts cannot change historical opt-in replay")
    expected_shared = args.condition == "fixed" or args.shared_cap == "true"
    receipt = args.output / "trial.json"
    record = {
        "status": "preparing",
        "label": args.label,
        "role": args.role,
        "performance_eligible": False,
        "timing_use": "diagnostic_only",
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "shared_cap": expected_shared,
        "comparison_axis": "baseline_vs_fixed_commit" if args.condition else "historical_optin",
        "condition": args.condition,
        "project_jobs": 8,
        "expected_shared_compiler_jobs": args.compiler_jobs,
        "scope": "Exact selected build step only; no full GitHub Actions or HOBL lifecycle claim.",
        "runner_sha256": sha256(__file__),
        "test_build_policy": TEST_BUILD_POLICY,
    }
    with receipt.open("x", encoding="utf-8") as output:
        json.dump(record, output, indent=2)
    try:
        ci_actual = assert_checkout(args.ci_root, args.ci_commit)
        source_actual = assert_checkout(args.source_root, args.source_commit)
        record["repositories"] = [
            {"repository": args.ci_repository, "branch_name": args.ci_branch,
             "target_commit_sha": args.ci_commit, "actual_commit_sha": ci_actual},
            {"repository": args.source_repository, "branch_name": args.source_branch,
             "target_commit_sha": args.source_commit, "actual_commit_sha": source_actual},
        ]
        cache = args.workdir / args.builddir / "CMakeCache.txt"
        record["cache_sha256"] = sha256(cache)
        if record["cache_sha256"] != args.cache_sha256.lower():
            raise ValueError("The configured cache differs from the frozen study configuration")
        homes = [
            line.partition("=")[2] for line in cache.read_text(encoding="utf-8").splitlines()
            if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL=")
        ]
        if len(homes) != 1 or not Path(homes[0]).samefile(args.source_root):
            raise ValueError("The configured build tree does not use the recorded OpenCV source checkout")
        record["native_dependency_check"] = check_native_python(args.workdir / args.builddir, args.architecture)
        action_path = args.ci_root / "configure-and-build" / "action.yml"
        prepared = json.loads((args.output / "prepared-step.json").read_text(encoding="utf-8"))
        inputs = build_step_inputs(args.workdir, args.builddir, args.shared_cap)
        script_file = args.output / "build-step.sh"
        if (prepared["ci_commit"] != args.ci_commit or prepared["inputs"] != inputs
                or prepared["comparison_axis"] != record["comparison_axis"]
                or prepared["condition"] != args.condition
                or prepared["action_sha256"] != sha256(action_path)
                or prepared["extracted_build_step_sha256"] != sha256(script_file)):
            raise ValueError("The prepared build step does not match the intended source/configuration")
        record["action_sha256"] = sha256(action_path)
        record["extracted_build_step_sha256"] = sha256(script_file)
        record["prepared_step_sha256"] = sha256(args.output / "prepared-step.json")
        record["inputs"] = inputs
        probe = Path(__file__).with_name("cmake_probe.py").resolve()
        probe_bin = args.output / "cmake-probe"
        probe_bin.mkdir()
        shim = probe_bin / "cmake.cmd"
        shim.write_text(
            '@echo off\n"{}" "{}" %*\nexit /b %errorlevel%\n'.format(sys.executable, probe),
            encoding="utf-8", newline="\r\n",
        )
        (probe_bin / "cmake").write_text(
            '#!/usr/bin/env bash\nexec "$OCV_PROBE_PYTHON" "$OCV_CMAKE_PROBE" "$@"\n',
            encoding="utf-8", newline="\n",
        )
        env = os.environ.copy()
        expected = ["--build", args.builddir, "--config", "Release"]
        if expected_shared:
            expected += [
                "--parallel", "8", "--", "/p:MultiProcCL=true",
                "/p:MultiProcMaxCount=" + str(args.compiler_jobs),
                "/p:EnforceProcessCountAcrossBuilds=true",
            ]
            if args.condition == "fixed":
                expected.append("/p:EnableClServerMode=true")
        if args.build_contract:
            from build_contract import validate_contract
            expected = validate_contract(args.build_contract, args.ci_commit, prepared, args.builddir)
            record["build_contract_sha256"] = sha256(args.build_contract)
            record["shared_cap"] = None
            record["expected_shared_compiler_jobs"] = None
        env.update({
            "RUNNER_OS": "Windows", "CMAKE_BUILD_PARALLEL_LEVEL": "8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "GITHUB_ACTION_PATH": (args.ci_root / "configure-and-build").as_posix(),
            "OCV_REAL_CMAKE": str(args.cmake),
            "OCV_CMAKE_RECEIPT": str(args.output / "cmake-invocation.json"),
            "OCV_PROBE_PYTHON": Path(sys.executable).as_posix(),
            "OCV_CMAKE_PROBE": probe.as_posix(),
            "OCV_EXPECTED_BUILD_ARGUMENTS": json.dumps(expected),
            "PATH": str(probe_bin) + os.pathsep + str(Path(sys.executable).parent)
                    + os.pathsep + str(args.cmake.parent) + os.pathsep + env["PATH"],
        })
        env.update(prepared["environment"])
        record["cmake_probe_sha256"] = sha256(probe)
        record["cmake_sha256"] = sha256(args.cmake)
        record["bash_sha256"] = sha256(args.bash)
        record["measurement_adapter"] = "Identical local PATH shim validates original action arguments, applies /nr:false to every measured build, and records the effective native command without modifying the action."
        result = subprocess.run(
            [str(args.bash), "--noprofile", "--norc", "-eo", "pipefail", script_file.as_posix()],
            cwd=args.workdir, env=env, check=False,
        )
        record["step_exit_code"] = result.returncode
        measured = json.loads((args.output / "cmake-invocation.json").read_text(encoding="utf-8"))
        record["native_build"] = measured
        if (result.returncode or measured["status"] != "success"
                or measured["arguments"] != expected
                or measured.get("test_build_policy") != TEST_BUILD_POLICY
                or measured.get("effective_arguments") != test_build_arguments(expected)):
            raise ValueError("Build failed or the actual native command differs from the frozen condition")
        assert_checkout(args.ci_root, args.ci_commit)
        assert_checkout(args.source_root, args.source_commit)
        if sha256(cache) != record["cache_sha256"]:
            raise ValueError("CMake configuration changed during the build")
        record["build_seconds"] = measured["build_seconds"]
        record["status"] = "build_succeeded_pending_correctness"
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record["status"] = "failed"
        record["error"] = str(error)
        print(str(error), file=sys.stderr)
        return 2
    finally:
        record["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        receipt.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
