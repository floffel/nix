#!/usr/bin/env python3
"""Export active CrowdSec decisions as Prometheus textfile metrics.

Reads `cscli decisions list -o json` on stdin. Labels include the IP, ban
type, origin, scenario ("why") and the remaining duration, so Grafana can
show what is blocked and for how much longer. Only active decisions are
exported, so series cardinality stays low.
"""

import json
import re
import socket
import sys

HOST = socket.gethostname()
DURATION_RE = re.compile(r"(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?")


def seconds(value: str) -> int:
    match = DURATION_RE.fullmatch(value or "")
    if not match:
        return 0
    days, hours, minutes, secs = (int(x or 0) for x in match.groups())
    return days * 86400 + hours * 3600 + minutes * 60 + secs


def label(value) -> str:
    text = str(value or "")
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> None:
    try:
        alerts = json.load(sys.stdin)
    except json.JSONDecodeError:
        alerts = []

    active = 0
    per_scenario = {}
    for alert in alerts:
        scenario = alert.get("scenario") or alert.get("message") or "unknown"
        origin = alert.get("kind") or alert.get("origin") or "unknown"
        per_scenario[scenario] = per_scenario.get(scenario, 0) + 1
        for decision in alert.get("decisions") or []:
            active += 1
            labels = (
                f'node="{label(HOST)}",ip="{label(decision.get("value"))}",'
                f'type="{label(decision.get("type"))}",origin="{label(origin)}",'
                f'scenario="{label(scenario)}"'
            )
            print(f"crowdsec_decision{{{labels}}} 1")
            print(
                "crowdsec_decision_remaining_seconds{"
                + labels
                + "} "
                + str(seconds(decision.get("duration", "")))
            )

    print(f'crowdsec_active_decisions{{node="{label(HOST)}"}} {active}')
    for scenario, count in per_scenario.items():
        print(
            'crowdsec_retained_alerts{node="%s",scenario="%s"} %d'
            % (label(HOST), label(scenario), count)
        )


if __name__ == "__main__":
    main()
