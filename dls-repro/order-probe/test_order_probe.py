import csv
import math
from pathlib import Path
import tempfile
import unittest

from analyze import analyze, contrasts, read_trials
from protocol import FILLS, schedule
from run import check_source


class OrderProbeTests(unittest.TestCase):
    def write_csv(self, path):
        with path.open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow("arm launch layout block order pair slot variant ns ns_per_fill".split())
            for _, _, slots in schedule():
                for row in slots:
                    # B takes 20% less time; slot two takes 10% more time for either variant.
                    duration = (800 if row[-1] == "B" else 1000) * (11 if row[-2] == 2 else 10)
                    writer.writerow((*row, FILLS * duration, duration))

    def test_balanced_estimates_separate_speedup_from_slot_cost(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "trials.csv"
            self.write_csv(path)
            for result in analyze(path).values():
                for name, item in result["contrasts_pct"].items():
                    want = -20 if name == "cached_vs_original" else 10
                    for value in (item["estimate"], *item["bootstrap95"], *item["by_link_order"].values()):
                        self.assertAlmostEqual(value, want)

    def test_slot_only_effect_is_not_an_implementation_effect(self):
        d = contrasts(dict.fromkeys(("AB", "BA", "AA", "BB"), math.log(0.9)))
        self.assertEqual(d["cached_vs_original"], 0)
        self.assertAlmostEqual(math.exp(d["slot2_vs_slot1_crossover"]), 0.9)

    def test_rejects_partial_reordered_and_invalid_durations(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "trials.csv"
            self.write_csv(path)
            rows = path.read_text().splitlines()
            bad_time = rows[1].rsplit(",", 2)[0] + ",0,0"
            for bad in (rows[:-1], rows + [rows[-1]], [rows[0], rows[2], rows[1], *rows[3:]],
                        [rows[0], bad_time, *rows[2:]]):
                with self.subTest(row_count=len(bad)):
                    path.write_text("\n".join(bad) + "\n")
                    with self.assertRaises(ValueError):
                        read_trials(path)

    def test_checker_line_endings_are_portable_but_code_changes_are_rejected(self):
        import shutil
        with tempfile.TemporaryDirectory() as root:
            src = Path(root) / "seed"
            shutil.copytree(Path(__file__).resolve().parents[1] / "seed", src)
            checker = src / "check.cpp"
            lf = checker.read_bytes().replace(b"\r\n", b"\n")
            for data in (lf, lf.replace(b"\n", b"\r\n")):
                checker.write_bytes(data)
                check_source(src)
            checker.write_bytes(lf + b"\nreturn;\n")
            with self.assertRaisesRegex(ValueError, "check.cpp"):
                check_source(src)


if __name__ == "__main__":
    unittest.main()
