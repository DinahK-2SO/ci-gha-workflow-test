import copy
import math
import unittest

from worker import COLUMNS, limits, same_result, schedule, summarize


def synthetic(launches=4, blocks=2, sweeps=7, seed=73):
    # A known code effect independent of a second-slot penalty.
    rows = []
    for _, slots in schedule(launches, blocks, seed):
        for s in slots:
            ns_per_fill = (80 if s[-1] == "B" else 100) * (11 if s[-2] == 2 else 10)
            rows.append(dict(zip(COLUMNS, (*s, 100+s[0], 3, 40*sweeps*ns_per_fill,
                                            ns_per_fill, 0, 1000000))))
    return rows


class RuntimeMatrixTests(unittest.TestCase):
    def test_replay_allows_libm_roundoff_not_changed_estimates_or_counts(self):
        actual = {"interval": [-1.3, 2.7], "slots": 384}
        recorded = copy.deepcopy(actual)
        recorded["interval"][1] = math.nextafter(2.7, math.inf)
        self.assertTrue(same_result(actual, recorded))
        recorded["slots"] = 383
        self.assertFalse(same_result(actual, recorded))
        recorded["slots"] = 384
        recorded["interval"][0] += 1e-6
        self.assertFalse(same_result(actual, recorded))

    def test_user_counts_and_seed_control_balanced_samples(self):
        s = list(schedule(6, 3, 7))
        self.assertNotEqual(s, list(schedule(6, 3, 99)))
        self.assertEqual(s, list(schedule(6, 3, 7)))
        for _, slots in s:
            for b in range(3):
                block = [r for r in slots if r[2] == b]
                self.assertCountEqual([r[4] for r in block[::2]], ["AB","BA","AA","BB"])
                self.assertEqual(sum(r[-1] == "A" for r in block), 4)
        with self.assertRaises(ValueError):
            limits(3, 3, 500)

    def test_known_effect_and_smoke_interval(self):
        for n in (2, 4):
            r = summarize(synthetic(launches=n), n, 2, 7, 73)
            for key, stats in r["contrasts_pct"].items():
                want = -20 if key == "cached_vs_original" else 10
                self.assertAlmostEqual(stats["estimate"], want)
                if n == 2:
                    self.assertIsNone(stats["bootstrap95"])
                else:
                    for x in stats["bootstrap95"]:
                        self.assertAlmostEqual(x, want)

    def test_reject_unpaired_or_mixed_process_or_cpu(self):
        rows = synthetic()
        for field, value in [("pid", 5), ("cpu", 2), ("variant", "X"), ("ns_per_fill", 1)]:
            bad = copy.deepcopy(rows)
            bad[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                summarize(bad, 4, 2, 7, 73)
        with self.assertRaises(ValueError):
            summarize(rows[:-1], 4, 2, 7, 73)
