#!/usr/bin/env python3
"""Move messages out of nested Maildir folders into Dovecot's maildir++ layout.

Dovecot stores every IMAP folder as ONE flat directory in the user's Maildir
root: the mailbox "Reports/Archive/Aggregate" lives in
``.Reports.Archive.Aggregate``.  A nested path such as
``.Reports/.Archive/Aggregate`` is therefore not a mailbox at all -- Dovecot
cannot address it, and every message inside it is unreachable from IMAP even
though it sits on disk with correct ownership.

parsedmarc's Maildir connection is exactly such a writer: it uses Python's
``mailbox.Maildir``, whose ``add_folder()`` nests subfolders inside the parent
directory (``Archive/Aggregate`` -> ``<maildir>/.Reports/.Archive/Aggregate``),
so its report archive lands where Dovecot cannot see it.  The same happens for
any script that pokes files into a Maildir with a naive path join.

This tool repairs that.  For every nested Maildir below --nested it

1. creates the corresponding mailbox through doveadm, so Dovecot owns the
   skeleton (``cur``/``new``/``tmp`` and the ``maildirfolder`` marker),
2. moves the message files into it,
3. restores Maildir ownership and modes (directories 0700, files 0600),
4. drops the nested directories it emptied, and
5. force-resyncs and subscribes the mailbox so clients see it immediately.

It never deletes a file and never removes a directory it did not empty.
The only files it ever unlinks are the housekeeping markers of a folder it has
just emptied (`maildirfolder` and Dovecot's own `dovecot-*`/`.dovecot*` index
files), because those are what keep an empty nested directory on disk.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

MAILDIR_SUBDIRS = ("cur", "new", "tmp")


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True)


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def is_housekeeping(name: str) -> bool:
    """Dovecot/maildir bookkeeping files -- never message content."""
    return name == "maildirfolder" or name.startswith(("dovecot-", ".dovecot"))


def mail_dirs(root: str, nested: str) -> list[str]:
    """Every directory at or below `nested` that looks like a Maildir folder."""
    found = []
    for dirpath, dirnames, _ in os.walk(nested):
        dirnames[:] = [d for d in dirnames if d not in ("cur", "new", "tmp")]
        if any(os.path.isdir(os.path.join(dirpath, s)) for s in MAILDIR_SUBDIRS):
            found.append(dirpath)
    found.sort(key=lambda p: (len(p.split(os.sep)), p))
    return found


def mailbox_names(root: str, path: str) -> tuple[str, str] | None:
    """(IMAP name, maildir++ flat directory) for a directory under `root`."""
    components = os.path.relpath(path, root).split(os.sep)
    names = [c.lstrip(".") for c in components]
    # maildir++ cannot express a folder name that itself contains a dot: the
    # flat form would be ambiguous.  Refuse rather than create a second
    # invisible folder -- the operator has to pick a different name.
    if any("." in n or not n for n in names):
        log(f"skipping {path}: folder name is not representable in maildir++")
        return None
    return "/".join(names), "." + ".".join(names)


def move_messages(src: str, dst: str, uid: int, gid: int) -> int:
    moved = 0
    for sub in ("cur", "new"):
        src_sub = os.path.join(src, sub)
        if not os.path.isdir(src_sub):
            continue
        dst_sub = os.path.join(dst, sub)
        os.makedirs(dst_sub, exist_ok=True)
        os.chmod(dst_sub, 0o700)
        for name in sorted(os.listdir(src_sub)):
            a = os.path.join(src_sub, name)
            b = os.path.join(dst_sub, name)
            if not os.path.isfile(a):
                continue
            if os.path.exists(b):
                log(f"keeping both copies, leaving {a} in place (name exists in {dst_sub})")
                continue
            shutil.move(a, b)
            os.chown(b, uid, gid)
            os.chmod(b, 0o600)
            moved += 1
    return moved


def prune(path: str, stop_at: str) -> int:
    """Remove `path` and its emptied children. Never removes a non-empty dir."""
    removed = 0
    for dirpath, dirnames, _ in os.walk(path, topdown=False):
        if os.path.commonpath([dirpath, stop_at]) != stop_at:
            continue
        for sub in MAILDIR_SUBDIRS:
            child = os.path.join(dirpath, sub)
            if os.path.isdir(child) and not os.listdir(child):
                os.rmdir(child)
                removed += 1
        # A folder holding nothing but its own markers carries no mail.  Python's
        # mailbox.Maildir leaves a `maildirfolder` marker behind, and without
        # dropping it the emptied nested scaffolding can never go away.
        leftovers = os.listdir(dirpath)
        if leftovers and all(is_housekeeping(n) for n in leftovers):
            for name in leftovers:
                os.remove(os.path.join(dirpath, name))
            removed += len(leftovers)
        if dirpath != stop_at and os.path.isdir(dirpath) and not os.listdir(dirpath):
            os.rmdir(dirpath)
            removed += 1
    return removed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--maildir", required=True, help="user's Maildir root")
    ap.add_argument("--user", required=True, help="Dovecot user, e.g. florian@minnecker.com")
    ap.add_argument("--nested", required=True, help="Maildir-relative nested tree, e.g. .Reports/.Archive")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.maildir)
    nested = os.path.abspath(os.path.join(root, args.nested))
    if os.path.commonpath([nested, root]) != root or nested == root:
        log(f"--nested must be a directory inside --maildir, got {nested}")
        return 2
    if not os.path.isdir(nested):
        print("nothing to do: nested tree does not exist")
        return 0

    st = os.stat(root)
    uid, gid = st.st_uid, st.st_gid
    plans = []
    for path in mail_dirs(root, nested):
        names = mailbox_names(root, path)
        if names is None:
            continue
        plans.append((path,) + names)

    if not plans:
        pruned = 0 if args.dry_run else prune(nested, root)
        print(f"nothing to do: no Maildir folders to flatten, removed {pruned} empty directories")
        return 0

    moved = 0
    touched = []
    for path, imap, flat in plans:
        dst = os.path.join(root, flat)
        if args.dry_run:
            log(f"dry-run: {path} -> {dst} (mailbox {imap})")
            continue
        # Let Dovecot build the skeleton; a non-zero exit means it already exists.
        created = run(["doveadm", "mailbox", "create", "-u", args.user, imap])
        if created.returncode != 0 and not os.path.isdir(dst):
            log(f"cannot create mailbox {imap}: {created.stderr.strip()}")
            return 1
        if not os.path.isdir(dst):
            os.makedirs(dst, exist_ok=True)
        os.chmod(dst, 0o700)
        os.chown(dst, uid, gid)
        marker = os.path.join(dst, "maildirfolder")
        if not os.path.exists(marker):
            open(marker, "a").close()
            os.chown(marker, uid, gid)
            os.chmod(marker, 0o600)
        n = move_messages(path, dst, uid, gid)
        moved += n
        touched.append(imap)
        log(f"{path} -> {imap}: {n} message(s)")

    if args.dry_run:
        return 0

    pruned = prune(nested, root)
    for imap in touched:
        run(["doveadm", "force-resync", "-u", args.user, imap])
        run(["doveadm", "mailbox", "subscribe", "-u", args.user, imap])
    print(f"flattened {len(touched)} mailbox(es), moved {moved} message(s), "
          f"removed {pruned} empty nested directories")
    return 0


if __name__ == "__main__":
    sys.exit(main())
