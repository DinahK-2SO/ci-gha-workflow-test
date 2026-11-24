"""Reporting policy for paired geometric time changes, conditional on two fixed layouts."""
import math
import random
from collections import defaultdict
from statistics import mean, variance

NEW_LAYOUT = "paired-layout-v2"
OLD_LAYOUT = "alternating-v1"


def launch_layouts(launches, seed, policy):
    if policy == OLD_LAYOUT:
        return ["AB", "BA"] * (launches // 2)
    if policy != NEW_LAYOUT:
        raise ValueError("Unknown layout policy: " + str(policy))
    # Independent RNG: changing layout order must not change slot randomization.
    rng = random.Random(f"dls-layout-v2:{seed}")
    pairs = launches // 2
    first = ["AB", "BA"] * (pairs // 2)
    if pairs % 2:
        first.append(rng.choice(("AB", "BA")))
    rng.shuffle(first)
    return [layout for start in first for layout in (start, start[::-1])]


def protocol(launches, blocks, sweeps, seed, cpu, band):
    if band is not None and (isinstance(band, bool) or not math.isfinite(band) or not 0 < band < 100):
        raise ValueError("practical_band_pct must be a finite number between 0 and 100 (exclusive)")
    return dict(schema=2, layout_policy=NEW_LAYOUT,
                estimand="order-balanced geometric B/A kernel time; percent change, negative faster",
                population="warm 40-fixture fill; one host/session/toolchain; conditional on two fixed linked binaries",
                uncertainty="approximate percentile bootstrap over whole launches within each fixed layout",
                stopping="fixed budget; no precision-based stopping, exclusions or automatic retries",
                launches=launches, launches_per_layout=launches//2, blocks=blocks, sweeps=sweeps,
                seed=seed, cpu=cpu, warmup_ms=1000, conditioning_sweeps=16, practical_band_pct=band)


def band_decision(ci, band):
    if band is None:
        return "no_band_declared"
    if ci is None:
        return "no_interval"
    low, high = ci
    if not math.isfinite(low) or not math.isfinite(high) or low > high:
        raise ValueError("Invalid interval")
    if high < -band:
        return "faster_beyond_band"
    if low > band:
        return "slower_beyond_band"
    if low >= -band and high <= band:
        return "interval_inside_band"
    return "inconclusive_at_band"


def _half_change(log_times):
    half = len(log_times) // 2
    if half == 0:
        return None
    return 100 * math.expm1(mean(log_times[-half:]) - mean(log_times[:half]))


def _lag1(series):
    # Do not stitch across process boundaries. Short or constant series have no useful diagnostic.
    if len(series) < 6:
        return None
    left, right = series[:-1], series[1:]
    mx, my = mean(left), mean(right)
    x = [a - mx for a in left]
    y = [a - my for a in right]
    denom = math.sqrt(sum(a*a for a in x) * sum(b*b for b in y))
    return sum(a*b for a, b in zip(x, y)) / denom if denom else None


def diagnostics(rows, clusters, metrics):
    """Describe validated, post-warm-up observations; never filter or change the primary estimate."""
    levels = defaultdict(list)
    for row in rows:
        levels[row["launch"], row["block"]].append(math.log(row["ns_per_fill"]))
    trace, by_layout = [], defaultdict(list)
    effect_s1, means_by_layout = [], defaultdict(list)
    for (layout, launch), records in sorted(clusters.items(), key=lambda kv: kv[0][1]):
        block_levels = [mean(levels[launch, b]) for b in range(len(records))]
        block_effects = [r["cached_vs_original"] for r in records]
        by_layout[layout].append(mean(block_levels))
        means_by_layout[layout].append(mean(block_effects))
        if len(records) > 1:
            effect_s1.append(variance(block_effects))
        trace.append(dict(launch=launch, layout=layout,
                          block_geomean_ns_per_fill=[math.exp(x) for x in block_levels],
                          block_cached_pct=[100*math.expm1(x) for x in block_effects],
                          late_vs_early_pct=_half_change(block_levels),
                          block_level_lag1=_lag1(block_levels)))
    layout_effect = metrics["cached_vs_original"]["by_link_order"]
    s1 = mean(effect_s1) if effect_s1 else None
    s2 = mean(variance(x) for x in means_by_layout.values()) if all(len(x)>1 for x in means_by_layout.values()) else None
    blocks = len(trace[0]["block_cached_pct"])
    return dict(launch_trace=trace, layout_effect_pct=layout_effect,
                layout_point_estimates_straddle_zero=min(layout_effect.values()) < 0 < max(layout_effect.values()),
                layout_spread_pp=max(layout_effect.values())-min(layout_effect.values()),
                launch_level_by_layout={k:dict(late_vs_early_pct=_half_change(v), lag1=_lag1(v))
                                        for k,v in by_layout.items()},
                pilot_log_effect_variance=dict(within_launch_block_variance=s1,
                                              within_layout_launch_mean_variance=s2,
                                              signed_launch_component=(s2-s1/blocks if s1 is not None and s2 is not None else None)))
