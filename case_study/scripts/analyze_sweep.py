#!/usr/bin/env python3
"""Aggregate a sweep produced by run_sweep.sh into a CSV, markdown table, and plots.

Usage:
  ./analyze_sweep.py <sweep_dir>
"""
import csv
import math
import re
import statistics
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


PERF_LINE = re.compile(r"^\s*([\d.]+)\s+([\d.]+)\s+Joules\s+(power/energy-\w+/)")


def parse_perf_ts(path):
    """Return list of (t_s, pkg_J, ram_J) merged by timestamp."""
    rows = {}  # t -> {pkg, ram}
    with open(path) as fh:
        for line in fh:
            m = PERF_LINE.match(line)
            if not m:
                continue
            t = float(m.group(1))
            j = float(m.group(2))
            ev = m.group(3)
            slot = rows.setdefault(t, {})
            if "pkg" in ev:
                slot["pkg"] = j
            elif "ram" in ev:
                slot["ram"] = j
    out = []
    for t in sorted(rows):
        out.append((t, rows[t].get("pkg", 0.0), rows[t].get("ram", 0.0)))
    return out


def perf_totals(ts):
    if not ts:
        return 0.0, 0.0, 0.0
    pkg = sum(r[1] for r in ts)
    ram = sum(r[2] for r in ts)
    dur = ts[-1][0]
    return pkg, ram, dur


def baseline_rates(path):
    """Return (pkg_W, ram_W) averaged over the idle baseline file."""
    ts = parse_perf_ts(path)
    if not ts:
        return 0.0, 0.0
    pkg, ram, dur = perf_totals(ts)
    if dur <= 0:
        return 0.0, 0.0
    return pkg / dur, ram / dur


def parse_fuzzer_stats(path):
    stats = {}
    if not path.exists():
        return stats
    with open(path) as fh:
        for line in fh:
            if ":" not in line:
                continue
            k, _, v = line.partition(":")
            stats[k.strip()] = v.strip()
    return stats


def parse_manifest(path):
    cells = []
    with open(path) as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            cells.append(row)
    return cells


def summarize(sweep_dir: Path):
    manifest = parse_manifest(sweep_dir / "manifest.tsv")
    base_pkg_W, base_ram_W = baseline_rates(sweep_dir / "idle_baseline.txt")

    per_cell = []
    for row in manifest:
        cell_dir = sweep_dir / row["cell_dir"]
        rep_dir = cell_dir / "rep-1"
        perf_path = rep_dir / "perf_stat.txt"
        stats_path = rep_dir / "out" / "default" / "fuzzer_stats"

        if not perf_path.exists():
            print(f"[!] missing perf for {row['cell_dir']}", file=sys.stderr)
            continue
        ts = parse_perf_ts(perf_path)
        pkg_J, ram_J, dur = perf_totals(ts)
        net_pkg = pkg_J - base_pkg_W * dur
        net_ram = ram_J - base_ram_W * dur

        st = parse_fuzzer_stats(stats_path)
        edges = int(st.get("edges_found", 0) or 0)
        execs = int(st.get("execs_done", 0) or 0)
        cvg_raw = st.get("bitmap_cvg", "0%").rstrip("%")
        try:
            cvg = float(cvg_raw)
        except ValueError:
            cvg = float("nan")
        crashes = int(st.get("saved_crashes", 0) or 0)

        per_cell.append({
            "target": row["target"],
            "config": row["config"],
            "rep": int(row["rep"]),
            "duration_s": dur,
            "pkg_J_raw": pkg_J,
            "ram_J_raw": ram_J,
            "pkg_J_net": net_pkg,
            "ram_J_net": net_ram,
            "execs": execs,
            "edges_found": edges,
            "bitmap_cvg_pct": cvg,
            "crashes": crashes,
            "J_per_edge": (net_pkg / edges) if edges else float("nan"),
            "ts": ts,
            "cell_dir": row["cell_dir"],
        })
    return per_cell, (base_pkg_W, base_ram_W)


def write_csv(per_cell, path):
    keys = ["target", "config", "rep", "duration_s",
            "pkg_J_raw", "pkg_J_net", "ram_J_raw", "ram_J_net",
            "execs", "edges_found", "bitmap_cvg_pct", "crashes", "J_per_edge"]
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        for c in per_cell:
            w.writerow({k: c[k] for k in keys})


def agg(per_cell, key):
    """Group by (target, config), return dict -> (mean, std, n)."""
    buckets = {}
    for c in per_cell:
        k = (c["target"], c["config"])
        buckets.setdefault(k, []).append(c[key])
    out = {}
    for k, vs in buckets.items():
        vs = [v for v in vs if isinstance(v, (int, float)) and not math.isnan(v)]
        if not vs:
            out[k] = (float("nan"), float("nan"), 0)
            continue
        m = statistics.mean(vs)
        s = statistics.stdev(vs) if len(vs) > 1 else 0.0
        out[k] = (m, s, len(vs))
    return out


def write_markdown(per_cell, baseline, path):
    targets = sorted({c["target"] for c in per_cell})
    configs = ["vanilla", "greenfuzz"]
    base_pkg_W, base_ram_W = baseline

    lines = []
    lines.append("# Sweep aggregate\n")
    lines.append(f"Idle baseline: **pkg = {base_pkg_W:.2f} W**, **ram = {base_ram_W:.2f} W**\n")
    lines.append("Net energies have baseline subtracted (`raw - rate * duration`).\n")

    for metric, label, unit in [
        ("pkg_J_net", "Net package energy", "J"),
        ("ram_J_net", "Net DRAM energy", "J"),
        ("execs", "Executions", ""),
        ("edges_found", "Edges found", ""),
        ("J_per_edge", "Energy per edge", "J/edge"),
    ]:
        a = agg(per_cell, metric)
        lines.append(f"## {label} ({unit})\n")
        header = "| target | " + " | ".join(configs) + " |"
        sep = "|---|" + "---|" * len(configs)
        lines.append(header)
        lines.append(sep)
        for t in targets:
            cells = []
            for cfg in configs:
                m, s, n = a.get((t, cfg), (float("nan"), float("nan"), 0))
                cells.append(f"{m:.2f} ± {s:.2f} (n={n})")
            lines.append(f"| {t} | " + " | ".join(cells) + " |")
        lines.append("")

    Path(path).write_text("\n".join(lines))


def plot_energy_ts(per_cell, out_dir: Path):
    by_target = {}
    for c in per_cell:
        by_target.setdefault(c["target"], []).append(c)

    for target, cells in by_target.items():
        fig, ax = plt.subplots(figsize=(8, 4.5))
        for c in cells:
            ts = c["ts"]
            if not ts:
                continue
            t = [r[0] for r in ts]
            pkg = [r[1] for r in ts]
            color = "C0" if c["config"] == "vanilla" else "C3"
            label = f"{c['config']} rep{c['rep']}"
            ax.plot(t, pkg, color=color, alpha=0.6, label=label, linewidth=1)
        ax.set_xlabel("time (s)")
        ax.set_ylabel("power/energy-pkg per 1 s (J)")
        ax.set_title(f"{target}: per-second package energy")
        ax.legend(fontsize=7, loc="best")
        fig.tight_layout()
        fig.savefig(out_dir / f"energy_ts_{target}.png", dpi=120)
        plt.close(fig)


def plot_edges_vs_energy(per_cell, out_dir: Path):
    fig, ax = plt.subplots(figsize=(7, 5))
    markers = {"jsoncpp": "o", "libjpeg_turbo": "s", "harfbuzz": "^"}
    for c in per_cell:
        m = markers.get(c["target"], "x")
        color = "C0" if c["config"] == "vanilla" else "C3"
        ax.scatter(c["pkg_J_net"], c["edges_found"], marker=m, color=color,
                   s=60, edgecolor="k", linewidth=0.5,
                   label=f"{c['target']} / {c['config']}")
    handles, labels = ax.get_legend_handles_labels()
    seen = {}
    for h, l in zip(handles, labels):
        seen.setdefault(l, h)
    ax.legend(seen.values(), seen.keys(), fontsize=8, loc="best")
    ax.set_xlabel("net package energy (J)")
    ax.set_ylabel("edges found")
    ax.set_title("Edges discovered vs. net energy (Pareto)")
    fig.tight_layout()
    fig.savefig(out_dir / "edges_vs_energy.png", dpi=120)
    plt.close(fig)


def plot_j_per_edge(per_cell, out_dir: Path):
    targets = sorted({c["target"] for c in per_cell})
    configs = ["vanilla", "greenfuzz"]
    a = agg(per_cell, "J_per_edge")

    x = np.arange(len(targets))
    width = 0.35
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for i, cfg in enumerate(configs):
        means = [a.get((t, cfg), (np.nan, 0, 0))[0] for t in targets]
        stds = [a.get((t, cfg), (np.nan, 0, 0))[1] for t in targets]
        ax.bar(x + (i - 0.5) * width, means, width, yerr=stds, capsize=4,
               label=cfg, color="C0" if cfg == "vanilla" else "C3")
    ax.set_xticks(x)
    ax.set_xticklabels(targets)
    ax.set_ylabel("J / edge")
    ax.set_title("Net package energy per edge (mean ± std)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_dir / "j_per_edge.png", dpi=120)
    plt.close(fig)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    sweep_dir = Path(sys.argv[1]).resolve()
    if not (sweep_dir / "manifest.tsv").exists():
        print(f"ERROR: no manifest.tsv in {sweep_dir}", file=sys.stderr)
        sys.exit(1)

    per_cell, baseline = summarize(sweep_dir)
    out_dir = sweep_dir
    write_csv(per_cell, out_dir / "summary.csv")
    write_markdown(per_cell, baseline, out_dir / "summary.md")
    plot_energy_ts(per_cell, out_dir)
    plot_edges_vs_energy(per_cell, out_dir)
    plot_j_per_edge(per_cell, out_dir)
    print(f"[+] wrote {out_dir}/summary.csv, summary.md, *.png")


if __name__ == "__main__":
    main()
