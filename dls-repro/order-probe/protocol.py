"""Frozen schedule used by the November 24 GCC runtime experiment."""
import random

SEED = 20261124
PAIRS = ("AB", "BA", "AA", "BB")
SWEEPS = 500
FILLS = 40 * SWEEPS


def schedule():
    rng = random.Random(SEED)
    for arm, launches, blocks in (("fresh", 8, 1), ("warm", 12, 4)):
        for group in range(launches):
            layout = "BA" if arm == "warm" and group % 2 else "AB"
            slots = []
            for block in range(blocks):
                for order, pattern in enumerate(rng.sample(PAIRS, len(PAIRS))):
                    for slot, variant in enumerate(pattern, 1):
                        launch = group if arm == "warm" else 8 * group + 2 * order + slot - 1
                        slots.append((arm, launch, layout, group if arm == "fresh" else block,
                                      order, pattern, slot, variant))
            yield arm, layout, slots
