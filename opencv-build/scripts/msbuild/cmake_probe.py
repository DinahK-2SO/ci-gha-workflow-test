import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time


TEST_BUILD_POLICY = {"msbuild_node_reuse": False}


def test_build_arguments(arguments):
    if not arguments or arguments[0] != "--build":
        raise ValueError("The local node-reuse policy requires a CMake build command")
    separator = arguments.index("--") if "--" in arguments else len(arguments)
    native = []
    for argument in arguments[separator + 1:]:
        switch, _, value = argument.lower().lstrip("/-").partition(":")
        if argument.startswith(("/", "-")) and switch in ("nr", "nodereuse"):
            if value != "false":
                raise ValueError("The action conflicts with the local /nr:false test policy")
        else:
            native.append(argument)
    return list(arguments[:separator]) + ["--"] + native + ["/nr:false"]


def main():
    receipt = Path(os.environ["OCV_CMAKE_RECEIPT"])
    executable = os.environ["OCV_REAL_CMAKE"]
    record = {
        "status": "running",
        "executable": executable,
        "arguments": sys.argv[1:],
        "test_build_policy": TEST_BUILD_POLICY,
        "working_directory": str(Path.cwd()),
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    with receipt.open("x", encoding="utf-8") as output:
        json.dump(record, output, indent=2)
    try:
        if "OCV_EXPECTED_BUILD_ARGUMENTS" in os.environ:
            expected = json.loads(os.environ["OCV_EXPECTED_BUILD_ARGUMENTS"])
            if sys.argv[1:] != expected:
                raise ValueError("Native build arguments differ from the frozen condition; build not launched")
        effective = test_build_arguments(sys.argv[1:])
        record["effective_arguments"] = effective
        print("Local test harness applies /nr:false; the selected action is unchanged.", flush=True)
        started = time.perf_counter()
        result = subprocess.run([executable] + effective, check=False)
        record["build_seconds"] = time.perf_counter() - started
        record["exit_code"] = result.returncode
        record["status"] = "success" if result.returncode == 0 else "failed"
        return result.returncode
    except (OSError, ValueError) as error:
        record["status"] = "failed"
        record["error"] = str(error)
        print(str(error), file=sys.stderr)
        return 2
    finally:
        record["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        receipt.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
