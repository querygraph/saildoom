"""Print a TPC-DOOM report's tables as Markdown, from the result files, so
no number in a report is typed by hand.

  report_tables.py tpc-doom/results/0001-capitola tpc-doom/results/0001-morrobay
"""

import json
import sys
from pathlib import Path

SUTS = (("cedardb", "CedarDB"), ("sail", "Sail (querygraph fork)"))


def f(x, digits):
    """x rounded half up from its shortest decimal text, as the adversari.al
    page's renderer rounds, so the two show the same digits."""
    from decimal import ROUND_HALF_UP, Decimal
    return str(Decimal(repr(x)).quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_UP))


def load(d, name):
    return json.loads((d / name).read_text())


def main():
    print("| Host | System | tpsD | RTF | Tics/s (T) | Tic ms p50 / p95 (T) | Frame ms p50 / p95 (R) "
          "| Slowest warm-up tic | First frame | tpsD, all runs | Test E |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    exact_rows = []
    for d in map(Path, sys.argv[1:]):
        host = d.name.split("-", 1)[1].capitalize()
        diffs = load(d, "frame-differences.json") if (d / "frame-differences.json").exists() else {"frames": []}
        other = [fr for fr in diffs["frames"] if not fr["cause"].startswith("libm")]
        libm = [fr for fr in diffs["frames"] if fr["cause"].startswith("libm")]
        for sut, label in SUTS:
            runs = [load(d, f"{sut}-run{i}.json") for i in (1, 2, 3)]
            r = sorted(runs, key=lambda x: x["realtime_test"]["tpsD"])[1]
            t, rt = r["tic_test"], r["realtime_test"]
            # Test E (SPEC.md): at most 1% of the frames may differ for reasons other than libm.
            verdict = "reference" if sut == "cedardb" else ("inexact" if len(other) > 0.01 * r["tics"] else "exact")
            print(f"| {host} | {label} | {f(rt['tpsD'], 2)} | {f(rt['realtime_factor'], 3)} | {f(t['tics_per_s'], 1)} "
                  f"| {f(t['tic']['p50_ms'], 1)} / {f(t['tic']['p95_ms'], 1)} | {f(rt['frame']['p50_ms'], 1)} / {f(rt['frame']['p95_ms'], 1)} "
                  f"| {f(t['warmup']['max_s'], 2)} s (tic {t['warmup']['max_at_tic']}) | {f(r['first_frame_s'], 2)} s "
                  f"| {' · '.join(f(x['realtime_test']['tpsD'], 2) for x in runs)} | {verdict} |")
        pixels = sorted(fr["pixels"] for fr in libm)
        exact_rows.append(f"| {host} | {len(libm)}" + (f", {pixels[0]} to {pixels[-1]} pixels" if pixels else "")
                          + " | " + ("; ".join(f"tic {fr['tic']}, {fr['pixels']:,} pixels: {fr['cause']}" for fr in other) or "none")
                          + " |")
    print("\n| Host | Frames differing by libm last bits | Other differences |\n|---|---|---|")
    print("\n".join(exact_rows))


if __name__ == "__main__":
    main()
