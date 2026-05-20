#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


SENDER_RE = re.compile(
    r"udp_sender sent=(?P<sent>\d+) feedback=(?P<feedback>\d+) "
    r"rr=(?P<rr>\d+) rate_caps=(?P<rate_caps>\d+) "
    r"pli_received=(?P<pli_received>\d+) idr_resends=(?P<idr_resends>\d+) "
    r"googcc_target_bps=(?P<googcc_target_bps>\d+) "
    r"final_target_bps=(?P<final_target_bps>\d+) rtt_ms=(?P<rtt_ms>\d+)"
)

SERVER_RE = re.compile(
    r"udp_server rtp_in=(?P<rtp_in>\d+) forwarded=(?P<forwarded>\d+) "
    r"dropped=(?P<dropped>\d+) reordered=(?P<reordered>\d+) "
    r"delayed=(?P<delayed>\d+) retransmitted=(?P<retransmitted>\d+) "
    r"rr_sent=(?P<rr_sent>\d+) rate_caps=(?P<rate_caps>\d+) "
    r"pli_forwarded=(?P<pli_forwarded>\d+)"
)

SERVER_QUALITY_RE = re.compile(
    r"udp_server quality loss_q8=(?P<loss_q8>\d+) jitter=(?P<jitter>\d+)"
)

RECEIVER_RE = re.compile(
    r"udp_receiver rtp=(?P<rtp>\d+) nack_sent=(?P<nack_sent>\d+) "
    r"pli_sent=(?P<pli_sent>\d+) frames=(?P<frames>\d+) "
    r"jitter_frames=(?P<jitter_frames>\d+)"
)

RECEIVER_FRAME_RE = re.compile(
    r"udp_receiver frame ts=(?P<timestamp>\d+) bytes=(?P<bytes>\d+) "
    r"keyframe=(?P<keyframe>[01])"
)


def ints(match):
    return {key: int(value) for key, value in match.groupdict().items()}


def parse_log(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    sender = {}
    server = {}
    receiver = {}
    quality_reports = []
    frames = []

    for line in text.splitlines():
        match = SENDER_RE.search(line)
        if match:
            sender = ints(match)
            continue
        match = SERVER_RE.search(line)
        if match:
            server = ints(match)
            continue
        match = SERVER_QUALITY_RE.search(line)
        if match:
            quality_reports.append(ints(match))
            continue
        match = RECEIVER_RE.search(line)
        if match:
            receiver = ints(match)
            continue
        match = RECEIVER_FRAME_RE.search(line)
        if match:
            frame = ints(match)
            frame["keyframe"] = bool(frame["keyframe"])
            frames.append(frame)

    return {
        "sender": sender,
        "server": server,
        "receiver": receiver,
        "quality_reports": quality_reports,
        "frames": frames,
    }


def derive(summary):
    sender = summary.get("sender", {})
    server = summary.get("server", {})
    receiver = summary.get("receiver", {})
    frames = summary.get("frames", [])
    quality_reports = summary.get("quality_reports", [])

    nack_sent = receiver.get("nack_sent", 0)
    retransmitted = server.get("retransmitted", 0)
    final_target = sender.get("final_target_bps", 0)
    googcc_target = sender.get("googcc_target_bps", 0)
    rtp_in = server.get("rtp_in", 0)
    dropped = server.get("dropped", 0)

    summary["derived"] = {
        "retransmission_success_ratio": (
            retransmitted / nack_sent if nack_sent else 0.0
        ),
        "receiver_frame_recovery_ok": receiver.get("frames", 0) >= 3,
        "sender_rate_cap_applied": final_target > 0
        and googcc_target > 0
        and final_target <= googcc_target,
        "observed_loss_fraction": dropped / rtp_in if rtp_in else 0.0,
        "keyframes": sum(1 for frame in frames if frame.get("keyframe")),
        "max_reported_loss_q8": max(
            [report.get("loss_q8", 0) for report in quality_reports] or [0]
        ),
        "max_reported_jitter_frames": max(
            [report.get("jitter", 0) for report in quality_reports] or [0]
        ),
    }
    return summary


def check_thresholds(summary, args):
    failures = []
    sender = summary.get("sender", {})
    server = summary.get("server", {})
    receiver = summary.get("receiver", {})
    derived = summary.get("derived", {})

    if sender.get("feedback", 0) < args.min_feedback:
        failures.append(f"feedback<{args.min_feedback}")
    if sender.get("rr", 0) < args.min_rr:
        failures.append(f"rr<{args.min_rr}")
    if sender.get("rate_caps", 0) < args.min_rate_caps:
        failures.append(f"rate_caps<{args.min_rate_caps}")
    if sender.get("pli_received", 0) < args.min_pli:
        failures.append(f"pli_received<{args.min_pli}")
    if server.get("retransmitted", 0) < args.min_retransmitted:
        failures.append(f"retransmitted<{args.min_retransmitted}")
    if receiver.get("nack_sent", 0) < args.min_nack:
        failures.append(f"nack_sent<{args.min_nack}")
    if receiver.get("frames", 0) < args.min_frames:
        failures.append(f"frames<{args.min_frames}")
    if derived.get("retransmission_success_ratio", 0.0) < args.min_retransmit_ratio:
        failures.append(f"retransmission_success_ratio<{args.min_retransmit_ratio}")
    if args.expect_rate_cap and not derived.get("sender_rate_cap_applied", False):
        failures.append("sender_rate_cap_not_applied")
    if args.expect_reorder and server.get("reordered", 0) <= 0:
        failures.append("reorder_not_observed")
    if args.expect_delay and server.get("delayed", 0) <= 0:
        failures.append("delay_not_observed")

    return failures


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def append_jsonl(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(data, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Collect UDP demo QoS/QoE metrics from a loopback log")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--jsonl", required=True, type=Path)
    parser.add_argument("--scenario", default="unknown")
    parser.add_argument("--run", type=int, default=1)
    parser.add_argument("--drop-seq", type=int, default=0)
    parser.add_argument("--reorder-seq", type=int, default=0)
    parser.add_argument("--delay-ms", type=int, default=0)
    parser.add_argument("--min-feedback", type=int, default=1)
    parser.add_argument("--min-rr", type=int, default=1)
    parser.add_argument("--min-rate-caps", type=int, default=1)
    parser.add_argument("--min-pli", type=int, default=1)
    parser.add_argument("--min-retransmitted", type=int, default=1)
    parser.add_argument("--min-nack", type=int, default=1)
    parser.add_argument("--min-frames", type=int, default=3)
    parser.add_argument("--min-retransmit-ratio", type=float, default=1.0)
    parser.add_argument("--expect-rate-cap", action="store_true")
    parser.add_argument("--expect-reorder", action="store_true")
    parser.add_argument("--expect-delay", action="store_true")
    args = parser.parse_args()

    summary = parse_log(args.log)
    summary.update({
        "scenario": args.scenario,
        "run": args.run,
        "netem": {
            "drop_seq": args.drop_seq,
            "reorder_seq": args.reorder_seq,
            "delay_ms": args.delay_ms,
        },
        "log": str(args.log),
    })
    derive(summary)
    failures = check_thresholds(summary, args)
    summary["thresholds"] = {
        "ok": not failures,
        "failures": failures,
    }

    write_json(args.summary, summary)
    append_jsonl(args.jsonl, summary)

    if failures:
        print("metrics threshold check failed: " + ", ".join(failures),
              file=sys.stderr)
        print(json.dumps(summary, indent=2, sort_keys=True), file=sys.stderr)
        return 1

    print(
        "metrics scenario={scenario} run={run} frames={frames} "
        "nack={nack} retransmitted={retransmitted} final_bps={final_bps} "
        "rtt_ms={rtt}".format(
            scenario=args.scenario,
            run=args.run,
            frames=summary.get("receiver", {}).get("frames", 0),
            nack=summary.get("receiver", {}).get("nack_sent", 0),
            retransmitted=summary.get("server", {}).get("retransmitted", 0),
            final_bps=summary.get("sender", {}).get("final_target_bps", 0),
            rtt=summary.get("sender", {}).get("rtt_ms", 0),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
