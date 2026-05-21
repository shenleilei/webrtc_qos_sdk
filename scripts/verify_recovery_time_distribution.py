#!/usr/bin/env python3
import argparse
import csv
import math
import os
import sys


DEFAULT_RECOVERABLE_SCENARIOS = {
    "bandwidth_cliff_recover",
    "weak_network_low_rps_low_bitrate",
    "walking_dead_zone_recover",
    "oscillating_edge_recover",
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Verify QoE recovery-time distribution across CSV rows."
    )
    parser.add_argument("csv", nargs="+", help="QoE CSV files to verify")
    parser.add_argument("--summary", default="", help="optional summary output file")
    parser.add_argument(
        "--recoverable-scenarios",
        default=",".join(sorted(DEFAULT_RECOVERABLE_SCENARIOS)),
        help="comma-separated scenarios that must recover",
    )
    parser.add_argument("--min-samples", type=int, default=1)
    parser.add_argument("--max-target-p95-ms", type=float, default=1000.0)
    parser.add_argument("--max-fps-p95-ms", type=float, default=1000.0)
    parser.add_argument("--max-full-p95-ms", type=float, default=1000.0)
    parser.add_argument("--max-target-ms", type=float, default=1000.0)
    parser.add_argument("--max-fps-ms", type=float, default=1000.0)
    parser.add_argument("--max-full-ms", type=float, default=1000.0)
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="also require every sampled row pass=true",
    )
    return parser.parse_args()


def as_float(row, key):
    value = row.get(key, "")
    if value in ("", None):
        return math.nan
    try:
        return float(value)
    except ValueError:
        return math.nan


def percentile(values, q):
    if not values:
        return math.nan
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * q
    lo = int(math.floor(rank))
    hi = int(math.ceil(rank))
    if lo == hi:
        return ordered[lo]
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def fmt(value):
    if math.isnan(value):
        return "nan"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return ("%.6f" % value).rstrip("0").rstrip(".")


def main():
    args = parse_args()
    recoverable = {
        item.strip()
        for item in args.recoverable_scenarios.split(",")
        if item.strip()
    }
    rows = []
    for path in args.csv:
        if not os.path.isfile(path):
            raise SystemExit("missing CSV: %s" % path)
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                scenario = row.get("scenario", "")
                if scenario in recoverable:
                    row["_source_csv"] = path
                    rows.append(row)

    if len(rows) < args.min_samples:
        raise SystemExit(
            "recovery sample count below minimum: %d < %d"
            % (len(rows), args.min_samples)
        )

    required_fields = [
        "target_recovery_time_ms",
        "fps_recovery_time_ms",
        "full_recovery_time_ms",
    ]
    missing = [
        field for field in required_fields if any(field not in row for row in rows)
    ]
    if missing:
        raise SystemExit("missing recovery fields: %s" % ",".join(sorted(missing)))

    values = {field: [] for field in required_fields}
    bad_rows = []
    failed_rows = []
    for row in rows:
        if args.require_pass and row.get("pass") != "true":
            failed_rows.append(row)
        for field in required_fields:
            value = as_float(row, field)
            if math.isnan(value) or value < 0:
                bad_rows.append((row, field, value))
            else:
                values[field].append(value)

    if failed_rows:
        raise SystemExit("sampled recovery rows have pass=false: %d" % len(failed_rows))
    if bad_rows:
        examples = []
        for row, field, value in bad_rows[:5]:
            examples.append(
                "%s/%s/%s %s=%s"
                % (
                    row.get("_source_csv", ""),
                    row.get("scenario", ""),
                    row.get("content_mode", row.get("seed", "")),
                    field,
                    value,
                )
            )
        raise SystemExit("invalid recovery values: %s" % "; ".join(examples))

    summary = {
        "recovery_distribution_verification": "true",
        "samples": str(len(rows)),
        "scenarios": ",".join(sorted({row.get("scenario", "") for row in rows})),
    }
    checks = [
        ("target_recovery_time_ms", args.max_target_p95_ms, args.max_target_ms),
        ("fps_recovery_time_ms", args.max_fps_p95_ms, args.max_fps_ms),
        ("full_recovery_time_ms", args.max_full_p95_ms, args.max_full_ms),
    ]
    violations = []
    for field, p95_limit, max_limit in checks:
        field_values = values[field]
        p50 = percentile(field_values, 0.50)
        p95 = percentile(field_values, 0.95)
        maximum = max(field_values)
        summary[field + "_p50"] = fmt(p50)
        summary[field + "_p95"] = fmt(p95)
        summary[field + "_max"] = fmt(maximum)
        summary[field + "_p95_limit"] = fmt(p95_limit)
        summary[field + "_max_limit"] = fmt(max_limit)
        if p95 > p95_limit:
            violations.append("%s p95 %s > %s" % (field, fmt(p95), fmt(p95_limit)))
        if maximum > max_limit:
            violations.append(
                "%s max %s > %s" % (field, fmt(maximum), fmt(max_limit))
            )

    lines = ["%s=%s" % (key, summary[key]) for key in sorted(summary)]
    if args.summary:
        with open(args.summary, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    for line in lines:
        print(line)
    if violations:
        raise SystemExit("recovery distribution failed: %s" % "; ".join(violations))


if __name__ == "__main__":
    main()
