"""Alertmanager -> ntfy formatter.

Alertmanager has no ntfy integration, and ntfy publishes the body it is given
verbatim (verified against ntfy.sh: a Slack-shaped payload comes out as the
raw JSON, so the Slack shim only moves the unreadability around). This bridge
takes Alertmanager's webhook payload and publishes one short plain-text
message with ntfy's Title/Priority/Tags headers.

Standard library only. Listens on loopback. The topic arrives through
EnvironmentFile, which systemd reads as root before dropping privileges, so
the topic never appears in the world-readable Nix store and the dynamic
service user never needs to read the secret file itself.
"""

import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOPIC = os.environ.get("NTFY_TOPIC", "").strip()
SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
# 9099, not 9094: Alertmanager binds 9093 for its web API and 9094 for the
# gossip cluster, so taking 9094 makes alertmanager fail to start with
# "bind: address already in use" (that is how this was first caught).
PORT = int(os.environ.get("NTFY_BRIDGE_PORT", "9099"))
MAX_ALERTS = 6
BODY_LIMIT = 300


def render(payload):
    status = str(payload.get("status", "firing")).lower()
    alerts = payload.get("alerts") or []

    names = sorted({str((a.get("labels") or {}).get("alertname", "alert")) for a in alerts})
    title = "%s: %s" % ("RESOLVED" if status == "resolved" else "FIRING", ", ".join(names))
    if len(alerts) > 1:
        title += " (%d alerts)" % len(alerts)

    lines = []
    for alert in alerts[:MAX_ALERTS]:
        labels = alert.get("labels") or {}
        annotations = alert.get("annotations") or {}
        where = labels.get("instance") or labels.get("job") or ""
        summary = (annotations.get("summary") or labels.get("alertname") or "alert").strip()
        detail = (annotations.get("description") or "").strip().replace("\n", " ")
        # Summaries already name the instance for most rules; repeating it
        # makes the line too long for a notification line.
        suffix = ""
        if where and where not in summary:
            suffix = " @ %s" % where
        lines.append("- %s%s" % (summary, suffix))
        if detail:
            lines.append("  %s" % detail[:BODY_LIMIT])
    if len(alerts) > MAX_ALERTS:
        lines.append("- ... and %d more" % (len(alerts) - MAX_ALERTS))

    critical = any((a.get("labels") or {}).get("severity") == "critical" for a in alerts)
    return title, "\n".join(lines) or title, ("high" if critical else None), (
        "rotating_light" if status != "resolved" else "white_check_mark"
    )


def publish(title, body, priority, tags):
    headers = {
        "Title": title,
        "Tags": tags,
        "Content-Type": "text/plain; charset=utf-8",
    }
    if priority:
        headers["Priority"] = priority
    request = urllib.request.Request("%s/%s" % (SERVER, TOPIC), data=body.encode("utf-8"), headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.status


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 would advertise keep-alive, and Alertmanager's webhook client
    # then holds the connection open. With a single-threaded server that one
    # idle connection stops every later page from being served -- curl got
    # "connection failed" while the service was up and delivering. So: threads,
    # and close each connection after its response.
    protocol_version = "HTTP/1.1"
    close_connection = True

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            title, body, priority, tags = render(json.loads(self.rfile.read(length).decode("utf-8")))
        except Exception as exc:
            print("bad webhook payload: %s" % exc, file=sys.stderr, flush=True)
            return self.reply(400)
        try:
            upstream = publish(title, body, priority, tags)
        except Exception as exc:
            # Non-2xx makes Alertmanager log and retry the notification.
            print("publish failed (%s): %s" % (title, exc), file=sys.stderr, flush=True)
            return self.reply(502)
        if not 200 <= upstream < 300:
            print("ntfy returned %s (%s)" % (upstream, title), file=sys.stderr, flush=True)
            return self.reply(502)
        self.reply(200)

    def do_GET(self):
        self.reply(200, b"ok\n")

    def log_message(self, fmt, *args):
        pass


def main():
    if not TOPIC:
        print("NTFY_TOPIC is not set; refusing to start", file=sys.stderr)
        return 1
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
