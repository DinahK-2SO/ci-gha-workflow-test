"""Reporting policy for paired geometric time changes, conditional on two fixed layouts."""
import math


def protocol(launches, blocks, sweeps, seed, cpu, band):
    if band is not None and (isinstance(band, bool) or not math.isfinite(band) or not 0 < band < 100):
        raise ValueError("practical_band_pct must be a finite number between 0 and 100 (exclusive)")
    return dict(schema=1, estimand="order-balanced geometric B/A kernel time; percent change, negative faster",
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
