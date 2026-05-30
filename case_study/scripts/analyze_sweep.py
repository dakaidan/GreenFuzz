#!/usr/bin/env python3
"""Analyze the sweep results: compute deltas, aggregate, and plot.
  con1 - con0  ~= 0          sanity  check
  con2 - con1  = D_meas      energy measurement overhead
  con3 - con2  = D_decision  behavioural effect of the heuristic
then aggregated (mean + CI, and median) across the reps of each target.

Because each machine runs only 2 units (2 targets x 1 rep), pass ALL the
machine sweep dirs at once (or a parent dir that contains them):

  ./analyze_sweep.py /local/sweep_m1_* /local/sweep_m2_* ...
  ./analyze_sweep.py /local                # parent: auto-discovers sweep_*/
"""
import csv
import math
import statistics
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import re


PERF_LINE = re.compile(r"^\s*([\d.]+)\s+([\d.,]+)\s+Joules\s+(power/energy-\w+/)")

# Config metadata -----------------------------------------------------------
CONFIG_ORDER = ["c0", "c1", "c2", "c3"]
CONFIG_LABEL = {
    "c0": "V·c0 vanilla",
    "c1": "B·c1 baseline",
    "c2": "L·c2 logging",
    "c3": "G·c3 greenfuzz",
}
CONFIG_COLOR = {"c0": "C0", "c1": "C2", "c2": "C1", "c3": "C3"}

# (minuend, subtrahend, label) -- all computed within a unit.
DELTAS = [
    ("c1", "c0", "B-V (sanity ~0)"),
    ("c2", "c1", "L-B  D_meas"),
    ("c3", "c2", "G-L  D_decision"),
]

# t_0.975 by degrees of freedom for small-sample 95% CIs (no scipy dependency).
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
       7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179}


def ci95_halfwidth(values):
    """95% CI half-width for the mean of a small sample (t-based)."""
    n = len(values)
    if n < 2:
        return float("nan")
    s = statistics.stdev(values)
    t = T95.get(n - 1, 1.96)
    return t * s / math.sqrt(n)


def parse_perf_ts(path):
    """Return list of (t_s, pkg_J, ram_J) merged by timestamp."""
    rows = {}
    with open(path) as fh:
        for line in fh:
            m = PERF_LINE.match(line)
            if not m:
                continue
            t = float(m.group(1))
            j = float(m.group(2).replace(",", ""))
            ev = m.group(3)
            slot = rows.setdefault(t, {})
            if "pkg" in ev:
                slot["pkg"] = j
            elif "ram" in ev:
                slot["ram"] = j
    return [(t, rows[t].get("pkg", 0.0), rows[t].get("ram", 0.0)) for t in sorted(rows)]


def perf_totals(ts):
    if not ts:
        return 0.0, 0.0, 0.0
    pkg = sum(r[1] for r in ts)
    ram = sum(r[2] for r in ts)
    dur = ts[-1][0]
    return pkg, ram, dur


def baseline_rates(sweep_dir: Path):
    """Average idle (pkg_W, ram_W) over all idle_baseline_*.txt in the dir."""
    files = sorted(sweep_dir.glob("idle_baseline*.txt"))
    pkg_ws, ram_ws = [], []
    for f in files:
        ts = parse_perf_ts(f)
        pkg, ram, dur = perf_totals(ts)
        if dur > 0:
            pkg_ws.append(pkg / dur)
            ram_ws.append(ram / dur)
    pkg_w = statistics.mean(pkg_ws) if pkg_ws else 0.0
    ram_w = statistics.mean(ram_ws) if ram_ws else 0.0
    return pkg_w, ram_w, len(files)


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
    with open(path) as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def summarize_dir(sweep_dir: Path):
    """Return per-cell records for one machine sweep dir (net energies use
    THIS machine's idle baseline)."""
    manifest = parse_manifest(sweep_dir / "manifest.tsv")
    base_pkg_W, base_ram_W, n_base = baseline_rates(sweep_dir)

    per_cell = []
    for row in manifest:
        # Tolerate manifests that lack the newer columns.
        config = row.get("config") or row.get("code")
        if config in ("V", "B", "L", "G"):  # in case only a code is present
            config = {"V": "c0", "B": "c1", "L": "c2", "G": "c3"}[config]
        machine = row.get("machine", "?")
        unit = row.get("unit", "?")
        # Unique replicate id for this (target) across the whole experiment.
        rep_id = f"m{machine}u{unit}"

        cell_dir = sweep_dir / row["cell_dir"]
        rep_dir = cell_dir / "rep-1"
        perf_path = rep_dir / "perf_stat.txt"
        stats_path = rep_dir / "out" / "default" / "fuzzer_stats"

        if not perf_path.exists():
            print(f"[!] missing perf for {sweep_dir.name}/{row['cell_dir']}", file=sys.stderr)
            continue
        ts = parse_perf_ts(perf_path)
        pkg_J, ram_J, dur = perf_totals(ts)
        net_pkg = pkg_J - base_pkg_W * dur
        net_ram = ram_J - base_ram_W * dur

        st = parse_fuzzer_stats(stats_path)
        edges = int(st.get("edges_found", 0) or 0)
        execs = int(st.get("execs_done", 0) or 0)
        try:
            cvg = float(st.get("bitmap_cvg", "0%").rstrip("%"))
        except ValueError:
            cvg = float("nan")
        crashes = int(st.get("saved_crashes", 0) or 0)

        per_cell.append({
            "machine": machine,
            "unit": unit,
            "rep_id": rep_id,
            "target": row["target"],
            "config": config,
            "code": row.get("code", ""),
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
            "uJ_per_exec": (net_pkg * 1e6 / execs) if execs else float("nan"),
            "ts": ts,
            "sweep_dir": sweep_dir.name,
            "cell_dir": row["cell_dir"],
        })
    if n_base:
        print(f"[i] {sweep_dir.name}: idle baseline pkg={base_pkg_W:.2f}W "
              f"ram={base_ram_W:.2f}W (n={n_base}), {len(per_cell)} cells")
    return per_cell


# --- delta analysis --------------------------------------------------------

def unit_deltas(per_cell, metric):
    """Group cells into units (target, rep_id) and compute the within-unit
    deltas for `metric`. Returns list of dicts, one per unit."""
    units = {}
    for c in per_cell:
        units.setdefault((c["target"], c["rep_id"]), {})[c["config"]] = c

    out = []
    for (target, rep_id), byc in sorted(units.items()):
        rec = {"target": target, "rep_id": rep_id}
        rec["_complete"] = all(cfg in byc for cfg in CONFIG_ORDER)
        for cfg in CONFIG_ORDER:
            rec[cfg] = byc[cfg][metric] if cfg in byc else float("nan")
        for hi, lo, label in DELTAS:
            if hi in byc and lo in byc:
                rec[label] = byc[hi][metric] - byc[lo][metric]
            else:
                rec[label] = float("nan")
        out.append(rec)
    return out


def agg_deltas(deltas):
    """Per-target aggregate (mean, CI half-width, median, n) of each delta."""
    by_target = {}
    for d in deltas:
        by_target.setdefault(d["target"], []).append(d)
    result = {}
    for target, rows in by_target.items():
        result[target] = {}
        for _, _, label in DELTAS:
            vals = [r[label] for r in rows
                    if isinstance(r[label], (int, float)) and not math.isnan(r[label])]
            if not vals:
                result[target][label] = (float("nan"), float("nan"), float("nan"), 0)
                continue
            mean = statistics.mean(vals)
            ci = ci95_halfwidth(vals)
            med = statistics.median(vals)
            result[target][label] = (mean, ci, med, len(vals))
    return result


def agg_metric(per_cell, key):
    """Group by (target, config); return dict -> (mean, std, n)."""
    buckets = {}
    for c in per_cell:
        buckets.setdefault((c["target"], c["config"]), []).append(c[key])
    out = {}
    for k, vs in buckets.items():
        vs = [v for v in vs if isinstance(v, (int, float)) and not math.isnan(v)]
        if not vs:
            out[k] = (float("nan"), float("nan"), 0)
        else:
            m = statistics.mean(vs)
            s = statistics.stdev(vs) if len(vs) > 1 else 0.0
            out[k] = (m, s, len(vs))
    return out


# --- outputs ---------------------------------------------------------------

def write_csv(per_cell, path):
    keys = ["sweep_dir", "machine", "unit", "rep_id", "target", "config", "code",
            "duration_s", "pkg_J_raw", "pkg_J_net", "ram_J_raw", "ram_J_net",
            "execs", "edges_found", "bitmap_cvg_pct", "crashes",
            "J_per_edge", "uJ_per_exec"]
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        for c in per_cell:
            w.writerow({k: c[k] for k in keys})


def write_deltas_csv(per_cell, path, metric):
    deltas = unit_deltas(per_cell, metric)
    labels = [lbl for _, _, lbl in DELTAS]
    keys = ["target", "rep_id", "_complete"] + CONFIG_ORDER + labels
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        for d in deltas:
            w.writerow({k: d.get(k, "") for k in keys})


def write_markdown(per_cell, path):
    targets = sorted({c["target"] for c in per_cell})
    lines = ["# Sweep aggregate\n"]

    # --- the headline: within-unit deltas of net package energy ---
    lines.append("## Energy deltas (net package J, within-unit, per target)\n")
    lines.append("Each value: **mean ± 95% CI** (median) over the reps of that target. "
                 "`B-V` should be ≈0; `L-B` is the measurement overhead; "
                 "`G-L` is the heuristic's behavioural effect.\n")
    dlabels = [lbl for _, _, lbl in DELTAS]
    lines.append("| target | " + " | ".join(dlabels) + " |")
    lines.append("|---|" + "---|" * len(dlabels))
    agg = agg_deltas(unit_deltas(per_cell, "pkg_J_net"))
    for t in targets:
        cells = []
        for lbl in dlabels:
            mean, ci, med, n = agg.get(t, {}).get(lbl, (float("nan"),) * 3 + (0,))
            cells.append(f"{mean:+.1f} ± {ci:.1f} ({med:+.1f}, n={n})")
        lines.append(f"| {t} | " + " | ".join(cells) + " |")
    lines.append("")

    # --- per-config absolute metrics ---
    for metric, label, unit in [
        ("pkg_J_net", "Net package energy", "J"),
        ("ram_J_net", "Net DRAM energy", "J"),
        ("execs", "Executions", ""),
        ("edges_found", "Edges found", ""),
        ("uJ_per_exec", "Energy per exec", "µJ/exec"),
        ("J_per_edge", "Energy per edge", "J/edge"),
    ]:
        a = agg_metric(per_cell, metric)
        lines.append(f"## {label} ({unit})\n")
        lines.append("| target | " + " | ".join(CONFIG_LABEL[c] for c in CONFIG_ORDER) + " |")
        lines.append("|---|" + "---|" * len(CONFIG_ORDER))
        for t in targets:
            cells = []
            for cfg in CONFIG_ORDER:
                m, s, n = a.get((t, cfg), (float("nan"), float("nan"), 0))
                cells.append(f"{m:.2f} ± {s:.2f} (n={n})")
            lines.append(f"| {t} | " + " | ".join(cells) + " |")
        lines.append("")

    Path(path).write_text("\n".join(lines))


def plot_deltas(per_cell, out_dir: Path):
    """Bar chart of the three energy deltas per target (mean ± 95% CI)."""
    agg = agg_deltas(unit_deltas(per_cell, "pkg_J_net"))
    targets = sorted(agg)
    dlabels = [lbl for _, _, lbl in DELTAS]
    x = np.arange(len(targets))
    width = 0.25
    fig, ax = plt.subplots(figsize=(8, 4.8))
    for i, lbl in enumerate(dlabels):
        means = [agg[t][lbl][0] for t in targets]
        cis = [agg[t][lbl][1] for t in targets]
        cis = [0 if (c != c) else c for c in cis]  # NaN -> 0
        ax.bar(x + (i - 1) * width, means, width, yerr=cis, capsize=4, label=lbl)
    ax.axhline(0, color="k", linewidth=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels(targets)
    ax.set_ylabel("Δ net package energy (J)")
    ax.set_title("Within-unit energy deltas (mean ± 95% CI across reps)")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out_dir / "energy_deltas.png", dpi=120)
    plt.close(fig)


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
            ax.plot([r[0] for r in ts], [r[1] for r in ts],
                    color=CONFIG_COLOR.get(c["config"], "k"),
                    alpha=0.5, linewidth=1)
        # one legend entry per config
        for cfg in CONFIG_ORDER:
            ax.plot([], [], color=CONFIG_COLOR[cfg], label=CONFIG_LABEL[cfg])
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
        ax.scatter(c["pkg_J_net"], c["edges_found"],
                   marker=markers.get(c["target"], "x"),
                   color=CONFIG_COLOR.get(c["config"], "k"),
                   s=60, edgecolor="k", linewidth=0.5,
                   label=f"{c['target']} / {CONFIG_LABEL[c['config']]}")
    handles, labels = ax.get_legend_handles_labels()
    seen = {}
    for h, l in zip(handles, labels):
        seen.setdefault(l, h)
    ax.legend(seen.values(), seen.keys(), fontsize=7, loc="best")
    ax.set_xlabel("net package energy (J)")
    ax.set_ylabel("edges found")
    ax.set_title("Edges discovered vs. net energy (Pareto)")
    fig.tight_layout()
    fig.savefig(out_dir / "edges_vs_energy.png", dpi=120)
    plt.close(fig)


def plot_j_per_edge(per_cell, out_dir: Path):
    targets = sorted({c["target"] for c in per_cell})
    a = agg_metric(per_cell, "J_per_edge")
    x = np.arange(len(targets))
    width = 0.2
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for i, cfg in enumerate(CONFIG_ORDER):
        means = [a.get((t, cfg), (np.nan, 0, 0))[0] for t in targets]
        stds = [a.get((t, cfg), (np.nan, 0, 0))[1] for t in targets]
        ax.bar(x + (i - 1.5) * width, means, width, yerr=stds, capsize=3,
               label=CONFIG_LABEL[cfg], color=CONFIG_COLOR[cfg])
    ax.set_xticks(x)
    ax.set_xticklabels(targets)
    ax.set_ylabel("J / edge")
    ax.set_title("Net package energy per edge (mean ± std)")
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(out_dir / "j_per_edge.png", dpi=120)
    plt.close(fig)


def discover_dirs(args):
    """Each arg is either a sweep dir (has manifest.tsv) or a parent dir."""
    dirs = []
    for a in args:
        p = Path(a).resolve()
        if (p / "manifest.tsv").exists():
            dirs.append(p)
        else:
            dirs.extend(sorted(d.parent for d in p.glob("**/manifest.tsv")))
    # de-dup preserving order
    seen, uniq = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            uniq.append(d)
    return uniq


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    dirs = discover_dirs(sys.argv[1:])
    if not dirs:
        print("ERROR: no manifest.tsv found under the given path(s)", file=sys.stderr)
        sys.exit(1)

    per_cell = []
    for d in dirs:
        per_cell.extend(summarize_dir(d))
    if not per_cell:
        print("ERROR: no usable cells", file=sys.stderr)
        sys.exit(1)

    # Output next to the first dir (or its parent if multiple machines).
    out_dir = dirs[0].parent if len(dirs) > 1 else dirs[0]
    write_csv(per_cell, out_dir / "summary.csv")
    write_deltas_csv(per_cell, out_dir / "deltas_pkg_J.csv", "pkg_J_net")
    write_markdown(per_cell, out_dir / "summary.md")
    plot_deltas(per_cell, out_dir)
    plot_energy_ts(per_cell, out_dir)
    plot_edges_vs_energy(per_cell, out_dir)
    plot_j_per_edge(per_cell, out_dir)

    # quick console digest of the headline deltas
    agg = agg_deltas(unit_deltas(per_cell, "pkg_J_net"))
    print(f"[+] {len(per_cell)} cells from {len(dirs)} machine dir(s)")
    print("[+] net-package-energy deltas (mean ± 95% CI, J):")
    for t in sorted(agg):
        parts = []
        for _, _, lbl in DELTAS:
            mean, ci, med, n = agg[t][lbl]
            parts.append(f"{lbl}={mean:+.1f}±{ci:.1f}(n={n})")
        print(f"    {t:14s} " + "  ".join(parts))
    print(f"[+] wrote {out_dir}/summary.csv, deltas_pkg_J.csv, summary.md, *.png")


if __name__ == "__main__":
    main()
