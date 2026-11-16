import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cmake_probe


class CMakeProbeTests(unittest.TestCase):
    def test_baseline_and_shared_commands_keep_original_options(self):
        baseline = ["--build", "build-portable", "--config", "Release"]
        for extra in (
            [],
            ["--parallel", "8", "--", "/p:MultiProcCL=true"],
            ["--parallel", "8", "--", "/p:EnableClServerMode=true"],
        ):
            with self.subTest(extra=extra):
                original = baseline + extra
                expected = original + ([] if "--" in original else ["--"]) + ["/nr:false"]
                self.assertEqual(cmake_probe.test_build_arguments(original), expected)
                self.assertEqual(original, baseline + extra)

    def test_false_is_normalized_and_conflicting_reuse_is_rejected(self):
        prefix = ["--build", "build", "--"]
        self.assertEqual(
            cmake_probe.test_build_arguments(prefix + ["/nodeReuse:False", "/p:Test=1", "/nr:false"]),
            prefix + ["/p:Test=1", "/nr:false"],
        )
        for switch in ("/nr", "/nr:true", "-nodeReuse:True", "/nr:invalid"):
            with self.subTest(switch=switch):
                with self.assertRaisesRegex(ValueError, "conflicts"):
                    cmake_probe.test_build_arguments(prefix + [switch])
        with self.assertRaisesRegex(ValueError, "requires a CMake build"):
            cmake_probe.test_build_arguments(["--version"])

    def invoke_probe(self, received, expected, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "invocation.json"
            environment = {
                "OCV_CMAKE_RECEIPT": str(receipt),
                "OCV_REAL_CMAKE": "fixture-cmake.exe",
                "OCV_EXPECTED_BUILD_ARGUMENTS": json.dumps(expected),
            }
            with patch.dict(os.environ, environment), \
                    patch.object(sys, "argv", ["cmake_probe.py"] + received), \
                    patch.object(cmake_probe.subprocess, "run",
                                 return_value=subprocess.CompletedProcess([], exit_code)) as run, \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = cmake_probe.main()
            return code, json.loads(receipt.read_text()), run

    def test_native_dispatch_and_receipt_distinguish_original_from_effective(self):
        original = ["--build", "build", "--config", "Release"]
        code, record, run = self.invoke_probe(original, original)
        effective = original + ["--", "/nr:false"]
        self.assertEqual(code, 0)
        run.assert_called_once_with(["fixture-cmake.exe"] + effective, check=False)
        self.assertEqual(record["arguments"], original)
        self.assertEqual(record["effective_arguments"], effective)
        self.assertEqual(record["test_build_policy"], {"msbuild_node_reuse": False})

    def test_argument_drift_or_policy_conflict_never_launches_native_build(self):
        expected = ["--build", "build", "--config", "Release"]
        conflict = expected + ["--", "/nr:true"]
        for received, frozen in ((expected + ["--parallel", "4"], expected), (conflict, conflict)):
            with self.subTest(received=received):
                code, record, run = self.invoke_probe(received, frozen)
                self.assertEqual(code, 2)
                self.assertEqual(record["status"], "failed")
                run.assert_not_called()

    def test_native_failure_is_not_reported_as_success(self):
        original = ["--build", "build"]
        code, record, _ = self.invoke_probe(original, original, exit_code=7)
        self.assertEqual(code, 7)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["exit_code"], 7)


if __name__ == "__main__":
    unittest.main()
