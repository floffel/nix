#!/usr/bin/env python3
"""Maildir visibility metrics for the node_exporter textfile collector.

A message can be on disk and still be unreachable from IMAP.  That happened
twice on this host and both times it looked exactly like lost mail:

* folders that exist on disk but are not subscribed -- clients build the
  folder pane from LSUB, so the whole tree stays hidden (November 2026);
* folders that live in a *nested* directory -- Dovecot's maildir++ layout
  stores every mailbox as one flat directory in the Maildir root, so
  ``.Reports/.Archive/Aggregate`` cannot be addressed at all.

Instead of trusting either side, compare all three views per account:

    on disk   : message files under cur/ and new/
    indexed   : what Dovecot reports (doveadm mailbox status messages)
    subscribed: what clients will actually show (doveadm mailbox list -s)

`mail_messages_unindexed` > 0 means mail that is on disk but invisible;
`mail_nested_maildir_dirs` > 0 means folders in a layout Dovecot cannot read.
Diagnostics go to stderr, metrics to stdout.
"""

from __future__ import annotations

import os
import subprocess
import sys
import logging

VMAIL = "/var/vmail"
SHARED_PREFIX = ".mail_shared"
MAILDIR_SUBDIRS = ("cur", "new", "tmp")

log = logging.getLogger("mail-health")


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def accounts() -> list[str]:
    """Canonical mailboxes: a real `maildir` directory, not an alias symlink.

    Secondary addresses are symlinked onto the canonical Maildir (see the
    "Secondary addresses" section of the README), so counting them again would
    only duplicate the canonical account's numbers.
    """
    out = []
    for domain in sorted(os.listdir(VMAIL)):
        dpath = os.path.join(VMAIL, domain)
        if not os.path.isdir(dpath) or domain.startswith(("$", "shared")):
            continue
        for user in sorted(os.listdir(dpath)):
            upath = os.path.join(dpath, user)
            if os.path.islink(upath) or not os.path.isdir(upath):
                continue
            maildir = os.path.join(upath, "maildir")
            if os.path.isdir(maildir) and not os.path.islink(maildir):
                out.append(f"{user}@{domain}")
    return out


def disk_view(maildir: str) -> tuple[int, int]:
    """(message files, nested maildir directories) below the Maildir root."""
    messages = 0
    nested = 0
    for dirpath, dirnames, filenames in os.walk(maildir):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(SHARED_PREFIX))
        rel = os.path.relpath(dirpath, maildir)
        depth = 0 if rel == "." else len(rel.split(os.sep))
        has_maildir = any(s in dirnames for s in MAILDIR_SUBDIRS)
        if has_maildir and depth > 1:
            # A Maildir folder that is not a single flat component of the
            # root: Dovecot's namespace cannot reach it.
            nested += 1
            log.warning("nested (unreadable) folder: %s", dirpath)
        if not has_maildir:
            continue
        for sub in list(dirnames):
            if sub in MAILDIR_SUBDIRS:
                for name in os.listdir(os.path.join(dirpath, sub)):
                    f = os.path.join(dirpath, sub, name)
                    if os.path.isfile(f) and not os.path.islink(f):
                        messages += 1
                dirnames.remove(sub)
    return messages, nested


def dovecot_view(user: str) -> tuple[int, int, int, int] | None:
    """(indexed messages of own folders, folders listed, folders subscribed)."""
    status = run(["doveadm", "mailbox", "status", "-u", user, "messages", "*"])
    if status.returncode != 0:
        log.warning("skipping %s: doveadm failed: %s", user, status.stderr.strip())
        return None
    indexed = 0
    folders = 0
    for line in status.stdout.splitlines():
        head, _, tail = line.rpartition(" messages=")
        if not tail.isdigit() or head.startswith("mail_shared"):
            continue
        indexed += int(tail)
        folders += 1
    listed = run(["doveadm", "mailbox", "list", "-u", user])
    subscribed = run(["doveadm", "mailbox", "list", "-s", "-u", user])
    return (indexed, folders,
            len([l for l in listed.stdout.splitlines() if l.strip()]),
            len([l for l in subscribed.stdout.splitlines() if l.strip()]))


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="mail-health: %(levelname)s: %(message)s")
    rows = []
    unhealthy = 0
    for user in accounts():
        local, _, domain = user.partition("@")
        maildir = os.path.join(VMAIL, domain, local, "maildir")
        if not os.path.isdir(maildir):
            # Never let a wrong path look like an empty, healthy mailbox.
            log.warning("%s: Maildir %s does not exist", user, maildir)
            unhealthy = 1
            continue
        on_disk, nested = disk_view(maildir)
        view = dovecot_view(user)
        if view is None:
            unhealthy = 1
            continue
        indexed, folders, listed, subscribed = view
        unindexed = max(on_disk - indexed, 0)
        hidden = max(listed - subscribed, 0)
        rows.append((user, on_disk, indexed, unindexed, nested, folders, listed, subscribed, hidden))
        if unindexed or nested:
            unhealthy = 1
            log.warning("%s: %d message(s) on disk but not indexed, %d nested folder(s)",
                        user, unindexed, nested)

    print("# HELP mail_messages_on_disk Message files in the Maildir (cur and new).")
    print("# TYPE mail_messages_on_disk gauge")
    print("# HELP mail_messages_indexed Messages Dovecot has indexed for the user.")
    print("# TYPE mail_messages_indexed gauge")
    print("# HELP mail_messages_unindexed Messages on disk that Dovecot cannot see.")
    print("# TYPE mail_messages_unindexed gauge")
    print("# HELP mail_nested_maildir_dirs Maildir folders in a layout Dovecot cannot read.")
    print("# TYPE mail_nested_maildir_dirs gauge")
    print("# HELP mail_folders_listed Mailboxes Dovecot lists.")
    print("# TYPE mail_folders_listed gauge")
    print("# HELP mail_folders_subscribed Mailboxes visible to IMAP clients.")
    print("# TYPE mail_folders_subscribed gauge")
    print("# HELP mail_hidden_folders Listed but unsubscribed mailboxes. Two \\Noselect")
    print("# parents (Migration-2026-11, mail_shared) are legitimately hidden.")
    print("# TYPE mail_hidden_folders gauge")
    print("# HELP mail_health_ok 1 when every mailbox reconciles disk against index.")
    print("# TYPE mail_health_ok gauge")
    for (user, on_disk, indexed, unindexed, nested, folders, listed, subscribed, hidden) in rows:
        q = f'user="{user}"'
        print(f'mail_messages_on_disk{{{q}}} {on_disk}')
        print(f'mail_messages_indexed{{{q}}} {indexed}')
        print(f'mail_messages_unindexed{{{q}}} {unindexed}')
        print(f'mail_nested_maildir_dirs{{{q}}} {nested}')
        print(f'mail_folders_listed{{{q}}} {folders}')
        print(f'mail_folders_subscribed{{{q}}} {subscribed}')
        print(f'mail_hidden_folders{{{q}}} {hidden}')
    print(f"mail_health_ok {0 if unhealthy else 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
