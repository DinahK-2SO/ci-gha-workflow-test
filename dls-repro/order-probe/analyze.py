"""Balanced log-time contrasts. Resample launch clusters (fresh arm: complete blocks)."""
from collections import defaultdict
import csv
import json
import math
from pathlib import Path
from random import Random
from statistics import mean, median, quantiles
import sys

from protocol import FILLS, PAIRS, SEED, schedule


def contrasts(log_second_first):
    d = log_second_first
    return {
        "cached_vs_original": (d["AB"] - d["BA"]) / 2,
        "slot2_vs_slot1_crossover": (d["AB"] + d["BA"]) / 2,
        "slot2_vs_slot1_same_A": d["AA"],
        "slot2_vs_slot1_same_B": d["BB"],
    }


def summarize_strata(strata, seed=SEED):
    """Geometric time contrasts; resample entire launches within each layout."""
    rng = Random(seed)
    estimate = mean(mean(s) for s in strata.values())
    pct = lambda x: 100 * math.expm1(x)
    interval = None
    if min(map(len, strata.values())) >= 2:
        draws = [mean(mean(rng.choices(s, k=len(s))) for s in strata.values()) for _ in range(10000)]
        q = quantiles(draws, n=1000, method="inclusive")
        interval = [pct(q[24]), pct(q[974])]
    return {"estimate": pct(estimate), "bootstrap95": interval,
            "by_link_order": {layout: pct(mean(s)) for layout, s in strata.items()}}


def read_trials(path):
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != "arm launch layout block order pair slot variant ns ns_per_fill".split():
            raise ValueError("Unexpected trial header")
        rows = list(reader)
    expected = [slot for _, _, slots in schedule() for slot in slots]
    if len(rows) != len(expected):
        raise ValueError(f"Incomplete protocol: expected {len(expected)} slots, got {len(rows)}")
    grouped = defaultdict(dict)
    for line, (r, want) in enumerate(zip(rows, expected), start=2):
        arm, launch, layout, block = r["arm"], int(r["launch"]), r["layout"], int(r["block"])
        order, pattern, slot = int(r["order"]), r["pair"], int(r["slot"])
        if (arm, launch, layout, block, order, pattern, slot, r["variant"]) != want:
            raise ValueError(f"Row {line} does not match the seeded protocol")
        ns = int(r["ns"])
        if None in r or ns <= 0 or ns / FILLS != float(r["ns_per_fill"]):
            raise ValueError(f"Invalid duration or fill count at row {line}")
        key = (arm, layout, block, 0) if arm == "fresh" else (arm, layout, launch, block)
        grouped[key].setdefault(pattern, {})[slot] = ns
    return rows, grouped


def analyze(path):
    rows, grouped = read_trials(path)
    clusters = defaultdict(list)
    second_faster = defaultdict(int)
    for (arm, layout, cluster, _), pairs in grouped.items():
        logratios = {}
        for p, slots in pairs.items():
            first, second = slots[1], slots[2]
            logratios[p] = math.log(second / first)
            second_faster[arm, p] += int(second < first)
        clusters[arm, layout, cluster].append(contrasts(logratios))

    results = {}
    for arm in ("fresh", "warm"):
        armrows = [r for r in rows if r["arm"] == arm]
        result = {"slots": len(armrows), "pairs_per_type": len(armrows) // 8,
                  "second_faster_count": {p: second_faster[arm, p] for p in ("AA", "AB", "BA", "BB")},
                  "cross_pair_median_ns_per_fill": {
                      v: median(float(r["ns_per_fill"]) for r in armrows
                                if r["variant"] == v and r["pair"] in ("AB", "BA")) for v in "AB"},
                  "contrasts_pct": {}}
        for name in contrasts(dict.fromkeys(PAIRS, 0)):
            strata = defaultdict(list)
            for (a, layout, _), records in sorted(clusters.items()):
                if a == arm:
                    strata[layout].append(mean(rec[name] for rec in records))
            result["contrasts_pct"][name] = summarize_strata(strata)
        results[arm] = result
    return results


def render_report(results, rows):
    lines = ["GCC DLS runtime: percent change in time (negative means faster).",
             "A = original; B = cached. Individual pairs below are in execution order (ns/fill).",
             "arm    layout block launch(first) pair          first        second"]
    for first, second in zip(rows[::2], rows[1::2]):
        lines.append(f"{first['arm']:5} {first['layout']:>6} {first['block']:>5} "
                     f"{first['launch']:>13} {first['pair']:>4} "
                     f"{float(first['ns_per_fill']):13.3f} {float(second['ns_per_fill']):13.3f}")
    lines.append("\nBounds below are approximate 95% cluster-bootstrap intervals.")
    for key, description in (("warm", "primary: warm, shared fixtures"), ("fresh", "secondary: fresh processes")):
        arm = results[key]
        counts = arm["second_faster_count"]
        cross_pairs = arm["pairs_per_type"] * 2
        lines.append(f"\n{description}: {arm['slots']} slots; second slot faster in "
                     f"{counts['AB'] + counts['BA']}/{cross_pairs} AB/BA comparisons.")
        for name, item in arm["contrasts_pct"].items():
            lo, hi = item["bootstrap95"]
            lines.append(f"  {name:28} {item['estimate']:+7.2f}%  [{lo:+.2f}%, {hi:+.2f}%]")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    print(json.dumps(analyze(Path(sys.argv[1])), indent=2))
