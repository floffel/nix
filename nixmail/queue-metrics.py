#!/usr/bin/env python3
"""Convert `postqueue -j` output to Prometheus textfile metrics."""

import json
import sys
from collections import Counter


def main() -> None:
    messages = Counter()
    size = Counter()
    recipients = Counter()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        queue = item.get("queue_name") or "unknown"
        messages[queue] += 1
        try:
            size[queue] += int(item.get("message_size") or 0)
        except (TypeError, ValueError):
            pass
        try:
            recipients[queue] += len(item.get("recipients") or [])
        except TypeError:
            pass

    for queue in sorted(set(messages) | {"active", "deferred", "hold", "incoming", "maildrop"}):
        print(f'postfix_queue_messages{{queue="{queue}"}} {messages.get(queue, 0)}')
        print(f'postfix_queue_size_bytes{{queue="{queue}"}} {size.get(queue, 0)}')
        print(f'postfix_queue_recipients{{queue="{queue}"}} {recipients.get(queue, 0)}')


if __name__ == "__main__":
    main()
