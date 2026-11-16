from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ci_action_trial import check_configured_workload, independent_workload, read_source_version


class IndependentWorkloadTests(unittest.TestCase):
    def test_source_version_is_not_pinned_to_one_opencv_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            header = root / "modules/core/include/opencv2/core/version.hpp"
            header.parent.mkdir(parents=True)
            for major, minor, patch, status, suffix in (
                (5, 2, 0, "-dev", "520"), (4, 12, 0, "", "4120"),
            ):
                with self.subTest(major=major):
                    header.write_text(
                        f'#define CV_VERSION_MAJOR {major}\n#define CV_VERSION_MINOR {minor}\n'
                        f'#define CV_VERSION_REVISION {patch}\n#define CV_VERSION_STATUS "{status}"\n'
                    )
                    self.assertEqual(read_source_version(root), {
                        "runtime_version": f"{major}.{minor}.{patch}{status}", "dll_suffix": suffix,
                    })
            header.write_text("#define CV_VERSION_MAJOR unknown\n")
            with self.assertRaisesRegex(ValueError, "source version"):
                read_source_version(root)

    def make_workload(self, root, overrides=None, modules=None):
        expected = independent_workload("ARM64")
        values = dict(expected["required_options"])
        values.update({
            "OPENCV_MODULES_BUILD": ";".join(modules or expected["minimum_modules"]),
            "PYTHON3_VERSION_STRING": "3.13.14",
        })
        values.update(overrides or {})
        (root / "CMakeCache.txt").write_text(
            "\n".join(f"{key}:STRING={value}" for key, value in values.items())
        )
        (root / "OpenCV.sln").write_text(
            'Project("{fixture}") = "opencv_core", "core.vcxproj", "{fixture}"\n'
        )
        return expected

    def test_independent_source_freezes_its_own_modules_and_features(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            modules = independent_workload("ARM64")["minimum_modules"] + ["opencv_new_module"]
            expected = self.make_workload(root, {"WITH_NEW_FEATURE": "ON"}, modules)
            result = check_configured_workload(root, expected)
            self.assertEqual(result["modules"], modules)
            self.assertEqual(result["feature_options"]["WITH_NEW_FEATURE"], "ON")
            self.assertEqual(result["projects"], ["opencv_core"])

    def test_changed_source_cannot_disable_required_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = self.make_workload(root, {"BUILD_TESTS": "OFF"})
            with self.assertRaisesRegex(ValueError, "feature options"):
                check_configured_workload(root, expected)
            expected = self.make_workload(root, modules=["opencv_core", "opencv_imgproc"])
            with self.assertRaisesRegex(ValueError, "Required OpenCV modules"):
                check_configured_workload(root, expected)

    def test_reference_inventory_remains_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = self.make_workload(root)
            expected["modules"] = expected.pop("minimum_modules") + ["opencv_reference_only"]
            with self.assertRaisesRegex(ValueError, "module set changed"):
                check_configured_workload(root, expected)


if __name__ == "__main__":
    unittest.main()
