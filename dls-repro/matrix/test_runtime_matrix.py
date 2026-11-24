import copy
import math
import unittest

from worker import COLUMNS, limits, same_result, schedule, summarize
from methodology import band_decision, launch_layouts, protocol, OLD_LAYOUT, NEW_LAYOUT


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
    def test_layout_positions_balanced_without_perturbing_slot_order(self):
        for launches in (2, 6, 12, 16, 32):
            for seed in (0, 73, 241124):
                layouts = launch_layouts(launches, seed, NEW_LAYOUT)
                self.assertEqual(layouts.count("AB"), launches//2)
                self.assertTrue(all(a != b for a,b in zip(layouts[::2], layouts[1::2])))
                self.assertLessEqual(abs(layouts[::2].count("AB")-layouts[::2].count("BA")), 1)
                old = schedule(launches, 3, seed, OLD_LAYOUT)
                new = schedule(launches, 3, seed, NEW_LAYOUT)
                for (_, oslots), (_, nslots) in zip(old, new):
                    self.assertEqual([s[2:] for s in oslots], [s[2:] for s in nslots])

    def test_diagnostics_surface_drift_and_opposing_layout_effects_without_dropping_data(self):
        rows = synthetic(launches=4, blocks=6)
        for r in rows:
            factor = (r["block"]+1) * (2 if (r["layout"]=="AB" and r["variant"]=="B") else 1)
            r["ns_per_fill"] *= factor
            r["ns"] *= factor
        diag = {}
        s = summarize(rows, 4, 6, 7, 73, diagnostic_output=diag)
        self.assertEqual(s["slots"], len(rows))
        self.assertTrue(diag["layout_point_estimates_straddle_zero"])
        self.assertEqual([x["launch"] for x in diag["launch_trace"]], list(range(4)))
        self.assertTrue(all(x["late_vs_early_pct"] > 0 and x["block_level_lag1"] > 0.8
                            for x in diag["launch_trace"]))
        short = {}
        summarize(synthetic(2, 1), 2, 1, 7, 73, diagnostic_output=short)
        self.assertIsNone(short["launch_trace"][0]["late_vs_early_pct"])
        self.assertIsNone(short["pilot_log_effect_variance"]["signed_launch_component"])

    def test_entire_interval_needed_for_practical_interpretation(self):
        for ci, band, expected in [
            ([-4,-2.1], 2, "faster_beyond_band"), ([2.1,4], 2, "slower_beyond_band"),
            ([-2,2], 2, "interval_inside_band"), ([-3,-1], 2, "inconclusive_at_band"),
            ([-4,-2], 2, "inconclusive_at_band"), ([-5,3], 2, "inconclusive_at_band"),
            (None, 2, "no_interval"), ([-6,-4], None, "no_band_declared")]:
            with self.subTest(ci=ci, band=band):
                self.assertEqual(band_decision(ci, band), expected)
        for band in [0, -2, 100, math.nan, math.inf, True]:
            with self.assertRaises(ValueError):
                protocol(16, 4, 500, 241124, -1, band)

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
