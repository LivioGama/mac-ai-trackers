#!/usr/bin/env python3
"""
Generate two PNGs from the CSVs produced by ratios-to-csv.py:

  - <prefix>-macro.png   : temporal scatter (X = midpoint timestamp).
  - <prefix>-scatter.png : hour-of-day scatter (X = local hour) with
                           shaded US peak-hour bands.

One color per account (vendor:account), marker size proportional to delta_5h
on the range (proxy for ratio reliability).

Dependency: matplotlib. See scripts/README.md for the venv setup.

Usage:
    ./ratios-to-png.py <prefix> [--out-prefix <out>] [--accounts-config <file>]

    <prefix>           : prefix used by ratios-to-csv.py
                         (reads <prefix>-macro.csv and <prefix>-scatter.csv)
    --out-prefix       : output PNG prefix (default: same as <prefix>)
    --accounts-config  : path to JSON file with account display names/colors
                         (auto-detects from CSV if not provided).
                         See accounts.example.json for format.
"""

import argparse
import csv
import json
from datetime import datetime
from pathlib import Path

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

# Default colors palette (used for auto-detected accounts).
DEFAULT_PALETTE = [
    "#3b82f6",  # blue
    "#ec4899",  # pink
    "#10b981",  # green
    "#f59e0b",  # amber
    "#6366f1",  # indigo
    "#8b5cf6",  # violet
    "#06b6d4",  # cyan
]

PEAK_COLOR = "#fbbf24"
PEAK_LABEL = "US peak hours (15-01 Paris)"
SIZE_REFS = (10, 50, 100)


def detect_accounts_from_csv(path: Path) -> dict[str, tuple[str, str]]:
    """Auto-detect (vendor:account) keys and assign colors from DEFAULT_PALETTE."""
    with path.open() as f:
        reader = csv.DictReader(f)
        # Skip first column (timestamp), look for account columns
        first_row = next(reader)
        if not first_row:
            return {}

    accounts = {}
    header_cols = list(first_row.keys())
    palette_idx = 0

    for col in header_cols[1:]:  # Skip first column (timestamp)
        if not col.endswith(":delta_5h"):
            # This is an account column (not the delta_5h companion)
            accounts[col] = (col, DEFAULT_PALETTE[palette_idx % len(DEFAULT_PALETTE)])
            palette_idx += 1

    return accounts


def load_accounts_config(path: Path) -> dict[str, tuple[str, str]]:
    """Load account display names/colors from JSON.
    Format: { "vendor:account": ["Display Name", "#hexcolor"], ... }
    Returns: { "vendor:account": (display_label, color), ... }
    """
    with path.open() as f:
        config = json.load(f)
    return {k: tuple(v) for k, v in config.items()}


def load_csv(path: Path, x_parser, series: dict):
    with path.open() as f:
        rows = list(csv.DictReader(f))
    data = {s: {"x": [], "ratio": [], "delta": []} for s in series}
    for r in rows:
        x_col = next(iter(r))
        x = x_parser(r[x_col])
        for s in series:
            ratio = r.get(s)
            d5 = r.get(f"{s}:delta_5h")
            if ratio:
                data[s]["x"].append(x)
                data[s]["ratio"].append(float(ratio))
                data[s]["delta"].append(float(d5))
    return data


def marker_sizes(deltas):
    # Area (points^2) proportional to delta_5h (%), with a small floor for visibility.
    return [max(5, d * 5) for d in deltas]


def color_handles(series: dict):
    return [
        Line2D([0], [0], marker="o", color="w", markerfacecolor=color,
               markersize=10, label=label)
        for _, (label, color) in series.items()
    ]


def size_handles():
    return [
        Line2D([0], [0], marker="o", color="w", markerfacecolor="gray",
               alpha=0.55, markersize=(d * 5) ** 0.5, label=f"delta_5h = {d}%")
        for d in SIZE_REFS
    ]


def plot_macro(csv_path: Path, png_path: Path, series: dict):
    data = load_csv(csv_path, lambda v: datetime.fromisoformat(v.replace("Z", "+00:00")), series)

    # Create figure with extra space for explanation text
    fig = plt.figure(figsize=(16, 9.5))
    gs = fig.add_gridspec(2, 1, height_ratios=[6, 1.2], hspace=0.15)

    # Top: chart
    ax = fig.add_subplot(gs[0])
    for s, (_, color) in series.items():
        d = data[s]
        if not d["x"]:
            continue
        ax.scatter(d["x"], d["ratio"], s=marker_sizes(d["delta"]), color=color,
                   alpha=0.7, edgecolors="white", linewidth=0.6)

    ax.set_xlabel("Time (UTC, range midpoint)")
    ax.set_ylabel("Macro ratio (x 5h windows to fill the 7d window)")
    ax.set_title("Macro 5h <-> 7d ratios — marker size = delta_5h on the range")
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%d %b"))
    ax.xaxis.set_major_locator(mdates.DayLocator(interval=2))
    ax.legend(handles=color_handles(series) + size_handles(),
              loc="center left", bbox_to_anchor=(1.01, 0.5),
              framealpha=0.9, fontsize=9)
    plt.setp(ax.xaxis.get_majorticklabels(), rotation=30)

    # Bottom: explanatory text
    ax_text = fig.add_subplot(gs[1])
    ax_text.axis('off')
    explanation = (
        "Macro ratio: measures how many times the 5h quota window must be saturated to fill the 7d quota window. "
        "Higher ratio = more 5h saturations needed before 7d saturates.\n"
        "Reliability: larger markers = higher delta_5h = more reliable ratio. Small markers are biased by integer rounding in API percentages; "
        "larger deltas mask rounding errors.\n"
        "[IMPORTANT] Ratios are comparable within the same plan, but absolute window sizes (5h/7d in tokens) may differ significantly across plans. "
        "A higher ratio does not mean more absolute capacity."
    )
    ax_text.text(0.02, 0.5, explanation, transform=ax_text.transAxes, fontsize=8.5,
                 ha='left', va='center', bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.6),
                 family='monospace', wrap=True)

    plt.savefig(png_path, dpi=130, bbox_inches="tight")
    plt.close()


def plot_scatter(csv_path: Path, png_path: Path, series: dict):
    data = load_csv(csv_path, float, series)

    # Create figure with extra space for explanation text
    fig = plt.figure(figsize=(16, 9.5))
    gs = fig.add_gridspec(2, 1, height_ratios=[6, 1.2], hspace=0.15)

    # Top: chart
    ax = fig.add_subplot(gs[0])
    ax.axvspan(15, 24, color=PEAK_COLOR, alpha=0.18)
    ax.axvspan(0, 1, color=PEAK_COLOR, alpha=0.18)
    for s, (_, color) in series.items():
        d = data[s]
        if not d["x"]:
            continue
        ax.scatter(d["x"], d["ratio"], s=marker_sizes(d["delta"]), color=color,
                   alpha=0.7, edgecolors="white", linewidth=0.6)

    peak_handle = Patch(facecolor=PEAK_COLOR, alpha=0.35, label=PEAK_LABEL)

    ax.set_xlabel("Hour of day (Paris, CEST)")
    ax.set_ylabel("Macro ratio (x 5h windows to fill the 7d window)")
    ax.set_title("5h <-> 7d ratio vs hour of day — marker size = delta_5h on the range")
    ax.set_xticks(range(0, 25, 2))
    ax.set_xlim(-0.5, 24.5)
    ax.grid(True, alpha=0.3)
    ax.legend(handles=color_handles(series) + [peak_handle] + size_handles(),
              loc="center left", bbox_to_anchor=(1.01, 0.5),
              framealpha=0.9, fontsize=9)

    # Bottom: explanatory text
    ax_text = fig.add_subplot(gs[1])
    ax_text.axis('off')
    explanation = (
        "Macro ratio: measures how many times the 5h quota window must be saturated to fill the 7d quota window. "
        "Higher ratio = more 5h saturations needed before 7d saturates.\n"
        "Reliability: larger markers = higher delta_5h = more reliable ratio. Small markers are biased by integer rounding in API percentages; "
        "larger deltas mask rounding errors.\n"
        "[IMPORTANT] Ratios are comparable within the same plan, but absolute window sizes (5h/7d in tokens) may differ significantly across plans. "
        "A higher ratio does not mean more absolute capacity."
    )
    ax_text.text(0.02, 0.5, explanation, transform=ax_text.transAxes, fontsize=8.5,
                 ha='left', va='center', bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.6),
                 family='monospace', wrap=True)

    plt.savefig(png_path, dpi=130, bbox_inches="tight")
    plt.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefix", type=Path,
                    help="Prefix used by ratios-to-csv.py (without -macro.csv/-scatter.csv)")
    ap.add_argument("--out-prefix", type=Path, default=None,
                    help="Output PNG prefix (default: same as prefix)")
    ap.add_argument("--accounts-config", type=Path, default=None,
                    help="Path to JSON file with account display names/colors")
    args = ap.parse_args()

    out_prefix = args.out_prefix or args.prefix
    macro_csv = args.prefix.with_name(args.prefix.name + "-macro.csv")
    scatter_csv = args.prefix.with_name(args.prefix.name + "-scatter.csv")
    macro_png = out_prefix.with_name(out_prefix.name + "-macro.png")
    scatter_png = out_prefix.with_name(out_prefix.name + "-scatter.png")

    for p in (macro_csv, scatter_csv):
        if not p.exists():
            raise SystemExit(f"CSV not found: {p}")

    # Load or auto-detect accounts
    if args.accounts_config:
        if not args.accounts_config.exists():
            raise SystemExit(f"Accounts config not found: {args.accounts_config}")
        series = load_accounts_config(args.accounts_config)
    else:
        series = detect_accounts_from_csv(macro_csv)
        if not series:
            raise SystemExit(f"No accounts detected in {macro_csv}")

    plot_macro(macro_csv, macro_png, series)
    plot_scatter(scatter_csv, scatter_png, series)
    print(f"PNGs written: {macro_png}, {scatter_png}")


if __name__ == "__main__":
    main()
