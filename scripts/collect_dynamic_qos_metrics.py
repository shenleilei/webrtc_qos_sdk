#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


DYNAMIC_RE = re.compile(
    r"dynamic_qos scenario=(?P<scenario>\S+) phase=(?P<phase>\S+) "
    r"estimate_bps=(?P<estimate_bps>\d+) final_bps=(?P<final_bps>\d+) "
    r"rtt_ms=(?P<rtt_ms>\d+) loss=(?P<loss>[0-9.]+) "
    r"encoder_bps=(?P<encoder_bps>\d+) max_fps=(?P<max_fps>\d+) "
    r"keyframe=(?P<keyframe>[01])"
)


def load_scenarios(path):
    scenarios = json.loads(path.read_text(encoding="utf-8"))
    return {scenario["name"]: scenario for scenario in scenarios}


def parse_log(path):
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = DYNAMIC_RE.search(line)
        if not match:
            continue
        row = match.groupdict()
        for key in ("estimate_bps", "final_bps", "rtt_ms", "encoder_bps",
                    "max_fps"):
            row[key] = int(row[key])
        row["loss"] = float(row["loss"])
        row["keyframe"] = bool(int(row["keyframe"]))
        rows.append(row)
    return rows


def check_scenario(scenario, rows):
    failures = []
    checks = []
    by_phase = {row["phase"]: row for row in rows}
    phases = [phase["name"] for phase in scenario.get("phases", [])]
    missing = [phase for phase in phases if phase not in by_phase]
    if missing:
        failures.append("missing_phases=" + ",".join(missing))
        return failures, checks

    for phase_config in scenario.get("phases", []):
        phase = phase_config["name"]
        row = by_phase[phase]
        expect = phase_config.get("expect", {})
        phase_checks = []
        for metric, actual_key in (
                ("encoder_bps_min", "encoder_bps"),
                ("encoder_bps_max", "encoder_bps"),
                ("max_fps_min", "max_fps"),
                ("max_fps_max", "max_fps")):
            if metric not in expect:
                continue
            actual = row[actual_key]
            expected = expect[metric]
            if metric.endswith("_min"):
                ok = actual >= expected
                op = ">="
            else:
                ok = actual <= expected
                op = "<="
            if not ok:
                failures.append(
                    f"{phase}_{actual_key}_{op}{expected}_actual={actual}")
            phase_checks.append({
                "metric": actual_key,
                "operator": op,
                "expected": expected,
                "actual": actual,
                "ok": ok,
            })
        if "keyframe" in expect:
            actual = row["keyframe"]
            expected = bool(expect["keyframe"])
            ok = actual == expected
            if not ok:
                failures.append(
                    f"{phase}_keyframe_expected={int(expected)}_actual={int(actual)}")
            phase_checks.append({
                "metric": "keyframe",
                "operator": "==",
                "expected": expected,
                "actual": actual,
                "ok": ok,
            })
        checks.append({
            "scenario": scenario["name"],
            "phase": phase,
            "network": {
                "bandwidth_kbps": phase_config.get("bandwidth_kbps"),
                "rtt_ms": phase_config.get("rtt_ms"),
                "loss": phase_config.get("loss"),
            },
            "actual": {
                "encoder_bps": row["encoder_bps"],
                "max_fps": row["max_fps"],
                "rtt_ms": row["rtt_ms"],
                "loss": row["loss"],
                "keyframe": row["keyframe"],
            },
            "checks": phase_checks,
            "ok": all(item["ok"] for item in phase_checks),
        })

    expect = scenario.get("expect", {})
    degraded_phases = expect.get("degraded_phases", [])
    recovered_phase = expect.get("recovered_phase")
    max_degraded_fps = expect.get("max_degraded_fps")
    min_recovered_fps = expect.get("min_recovered_fps")
    baseline = by_phase[phases[0]]
    recovered = by_phase.get(recovered_phase) if recovered_phase else None

    if max_degraded_fps is not None:
        for phase in degraded_phases:
            row = by_phase[phase]
            if row["max_fps"] > max_degraded_fps:
                failures.append(f"{phase}_fps>{max_degraded_fps}")

    if min_recovered_fps is not None and recovered:
        if recovered["max_fps"] < min_recovered_fps:
            failures.append(f"{recovered_phase}_fps<{min_recovered_fps}")

    for phase in expect.get("require_keyframe_phases", []):
        if not by_phase[phase]["keyframe"]:
            failures.append(f"{phase}_missing_keyframe_request")

    if expect.get("require_bitrate_drop", False):
        for phase in degraded_phases:
            if by_phase[phase]["encoder_bps"] >= baseline["encoder_bps"]:
                failures.append(f"{phase}_bitrate_not_below_baseline")

    if expect.get("require_bitrate_recovery", False) and recovered:
        worst_degraded = min(
            [by_phase[phase]["encoder_bps"] for phase in degraded_phases] or
            [baseline["encoder_bps"]])
        if recovered["encoder_bps"] <= worst_degraded:
            failures.append(f"{recovered_phase}_bitrate_not_recovered")

    return failures, checks


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def append_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Collect dynamic QoS adaptation metrics")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--scenarios", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--jsonl", required=True, type=Path)
    args = parser.parse_args()

    expected = load_scenarios(args.scenarios)
    rows = parse_log(args.log)
    if not rows:
        print("no dynamic_qos rows found", file=sys.stderr)
        return 1

    rows_by_scenario = {}
    for row in rows:
        rows_by_scenario.setdefault(row["scenario"], []).append(row)

    threshold_failures = []
    quantitative_checks = []
    for name, scenario in expected.items():
        failures, checks = check_scenario(
            scenario, rows_by_scenario.get(name, []))
        quantitative_checks.extend(checks)
        if failures:
            threshold_failures.append({
                "scenario": name,
                "failures": failures,
            })

    missing_scenarios = sorted(set(expected) - set(rows_by_scenario))
    for name in missing_scenarios:
        threshold_failures.append({
            "scenario": name,
            "failures": ["scenario_not_executed"],
        })

    fps_values = [row["max_fps"] for row in rows]
    bitrate_values = [row["encoder_bps"] for row in rows]
    keyframe_requests = sum(1 for row in rows if row["keyframe"])
    summary = {
        "rows": len(rows),
        "scenarios": sorted(rows_by_scenario),
        "threshold_failures": threshold_failures,
        "fps": {
            "min": min(fps_values),
            "max": max(fps_values),
        },
        "encoder_bps": {
            "min": min(bitrate_values),
            "max": max(bitrate_values),
        },
        "keyframe_requests": keyframe_requests,
        "quantitative_checks": quantitative_checks,
    }

    write_json(args.summary, summary)
    append_jsonl(args.jsonl, rows)

    if threshold_failures:
        print(json.dumps(summary, indent=2, sort_keys=True), file=sys.stderr)
        return 1

    print(
        "dynamic qos metrics passed scenarios={scenarios} fps_min={fps_min} "
        "fps_max={fps_max} bitrate_min={bitrate_min} bitrate_max={bitrate_max} "
        "keyframes={keyframes}".format(
            scenarios=len(rows_by_scenario),
            fps_min=summary["fps"]["min"],
            fps_max=summary["fps"]["max"],
            bitrate_min=summary["encoder_bps"]["min"],
            bitrate_max=summary["encoder_bps"]["max"],
            keyframes=summary["keyframe_requests"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
