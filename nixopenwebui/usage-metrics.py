#!/usr/bin/env python3
"""Export Open WebUI user/chat activity from SQLite to Prometheus textfile."""

import sqlite3
import time

DB = "/var/lib/private/open-webui/data/webui.db"


def main() -> None:
    now = int(time.time())
    db = sqlite3.connect(DB)
    rows = list(db.execute("select email, role, last_active_at from user"))
    active_15m = sum(1 for _, _, t in rows if t and now - int(t) <= 900)
    active_1h = sum(1 for _, _, t in rows if t and now - int(t) <= 3600)
    chats = db.execute("select count(*) from chat").fetchone()[0]

    print(f"openwebui_users_active_15m {active_15m}")
    print(f"openwebui_users_active_1h {active_1h}")
    print(f"openwebui_users_total {len(rows)}")
    print(f"openwebui_chats_total {chats}")

    for email, role, last_active in rows:
        user = (email or "unknown").split("@")[0]
        age = max(0, now - int(last_active)) if last_active else 999999999
        print(
            f'openwebui_user_last_active_seconds{{user="{user}",role="{role}"}} {age}'
        )


if __name__ == "__main__":
    main()
