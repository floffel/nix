#!/usr/bin/env python3
"""Read-only IMAP API for Open WebUI.

Open WebUI calls this as an OpenAPI tool server and forwards the
authenticated user's e-mail address in X-OpenWebUI-User-Email (the header
name is Open WebUI's default). The API impersonates exactly that mailbox via
a Dovecot master user and never accepts a user/mailbox identity from the
model. Everything is read-only: no flags are set, nothing is moved/deleted.
"""

import email
import html
import imaplib
import ipaddress
import json
import os
import re
import sys
from email.header import decode_header, make_header
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ADDR = os.environ.get("MAIL_API_ADDR", "10.20.20.13")
PORT = int(os.environ.get("MAIL_API_PORT", "8081"))
MASTER_USER = os.environ.get("MAIL_API_MASTER_USER", "mailapi")
IMAP_HOST = os.environ.get("MAIL_API_IMAP_HOST", "127.0.0.1")
IMAP_PORT = int(os.environ.get("MAIL_API_IMAP_PORT", "143"))
MAX_BODY = 20000
DEFAULT_LIMIT = 10
MAX_LIMIT = 50

ALLOWED_NETS = [
    ipaddress.ip_network(n.strip())
    for n in os.environ.get("MAIL_API_ALLOW", "").split(",")
    if n.strip()
]
USER_RE = re.compile(r"^[a-z0-9][a-z0-9._%+-]*@minnecker\.com$")
MAILBOX_RE = re.compile(r"^[A-Za-z0-9._@/-]+$")


def read_master_password() -> str:
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY", "/run/credentials/mail-api.service")
    with open(os.path.join(cred_dir, "imap-master-password"), encoding="utf-8") as fh:
        return fh.read().strip()


MASTER_PASSWORD = read_master_password()


def hdr(value) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(str(value))))
    except Exception:
        return str(value)


class _TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in ("br", "p", "div", "tr", "li"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def strip_html(text: str) -> str:
    parser = _TextExtractor()
    try:
        parser.feed(text)
        text = "".join(parser.parts)
    except Exception:
        text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"[ \t]+", " ", re.sub(r"\n{3,}", "\n\n", text)).strip()


def body_text(msg) -> str:
    plain = None
    html_body = None
    for part in msg.walk():
        ctype = part.get_content_type()
        if part.get_content_maintype() == "multipart":
            continue
        if "attachment" in (part.get("Content-Disposition") or "").lower():
            continue
        payload = part.get_payload(decode=True)
        if payload is None:
            continue
        text = payload.decode(part.get_content_charset() or "utf-8", "replace")
        if ctype == "text/plain" and plain is None:
            plain = text
        elif ctype == "text/html" and html_body is None:
            html_body = strip_html(text)
    text = plain if plain is not None else (html_body or "")
    return text.strip()[:MAX_BODY]


def attachments(msg):
    names = []
    for part in msg.walk():
        name = part.get_filename()
        if name:
            names.append(hdr(name))
    return names


def imap_for(user: str) -> imaplib.IMAP4:
    conn = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
    conn.login(f"{user}*{MASTER_USER}", MASTER_PASSWORD)
    return conn


def check_mailbox(name: str) -> str:
    if not name or not MAILBOX_RE.match(name) or ".." in name:
        raise ValueError("invalid mailbox")
    return name


def fetch_headers(conn, uid: bytes) -> dict:
    typ, data = conn.fetch(
        uid, "(BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)])"
    )
    raw = b"".join(part[1] for part in data if isinstance(part, tuple))
    msg = email.message_from_bytes(raw)
    return {
        "uid": uid.decode(),
        "from": hdr(msg.get("From")),
        "to": hdr(msg.get("To")),
        "cc": hdr(msg.get("Cc")),
        "subject": hdr(msg.get("Subject")),
        "date": hdr(msg.get("Date")),
    }


def list_recent(user: str, mailbox: str, limit: int) -> list:
    conn = imap_for(user)
    try:
        conn.select(check_mailbox(mailbox), readonly=True)
        typ, data = conn.search(None, "ALL")
        if typ != "OK":
            raise RuntimeError("search failed")
        uids = data[0].split()[-limit:]
        return [fetch_headers(conn, uid) for uid in reversed(uids)]
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def search(user: str, mailbox: str, query: str, limit: int) -> list:
    conn = imap_for(user)
    try:
        conn.select(check_mailbox(mailbox), readonly=True)
        quoted = '"' + query.replace("\\", "\\\\").replace('"', '\\"') + '"'
        typ, data = conn.search(None, "TEXT", quoted)
        if typ != "OK":
            raise RuntimeError("search failed")
        uids = data[0].split()[-limit:]
        return [fetch_headers(conn, uid) for uid in reversed(uids)]
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def read_message(user: str, mailbox: str, uid: str) -> dict:
    if not uid.isdigit():
        raise ValueError("invalid uid")
    conn = imap_for(user)
    try:
        conn.select(check_mailbox(mailbox), readonly=True)
        typ, data = conn.fetch(uid.encode(), "(BODY.PEEK[])")
        if typ != "OK" or not data or not isinstance(data[0], tuple):
            raise LookupError("message not found")
        msg = email.message_from_bytes(data[0][1])
        return {
            "uid": uid,
            "from": hdr(msg.get("From")),
            "to": hdr(msg.get("To")),
            "cc": hdr(msg.get("Cc")),
            "subject": hdr(msg.get("Subject")),
            "date": hdr(msg.get("Date")),
            "attachments": attachments(msg),
            "text": body_text(msg),
        }
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def mailboxes(user: str) -> list:
    conn = imap_for(user)
    try:
        typ, data = conn.list()
        if typ != "OK":
            return []
        names = []
        for line in data:
            if not line:
                continue
            text = line.decode("utf-8", "replace")
            match = re.search(r'"([^"]*)"$', text)
            names.append(match.group(1) if match else text.split()[-1])
        return names
    finally:
        try:
            conn.logout()
        except Exception:
            pass


SPEC = {
    "openapi": "3.0.3",
    "info": {
        "title": "Mail (read-only)",
        "version": "1.0.0",
        "description": (
            "Read-only access to the mailbox of the user who is currently logged in. "
            "You never need to ask for an e-mail address: the API always uses the "
            "authenticated user. Use list_recent_mail or search_mail to find messages, "
            "then read_mail with the returned uid to read one message."
        ),
    },
    "paths": {
        "/mail/recent": {
            "get": {
                "operationId": "list_recent_mail",
                "summary": "List the most recent e-mails of the logged-in user",
                "parameters": [
                    {
                        "name": "mailbox",
                        "in": "query",
                        "schema": {"type": "string", "default": "INBOX"},
                        "description": "Mailbox name, e.g. INBOX, Junk, Reports",
                    },
                    {
                        "name": "limit",
                        "in": "query",
                        "schema": {"type": "integer", "default": 10, "maximum": 50},
                    },
                ],
                "responses": {"200": {"description": "Recent messages"}},
            }
        },
        "/mail/search": {
            "get": {
                "operationId": "search_mail",
                "summary": "Search the logged-in user's mailbox",
                "description": "Full-text IMAP search (headers and body), newest matches first.",
                "parameters": [
                    {
                        "name": "query",
                        "in": "query",
                        "required": True,
                        "schema": {"type": "string"},
                    },
                    {
                        "name": "mailbox",
                        "in": "query",
                        "schema": {"type": "string", "default": "INBOX"},
                    },
                    {
                        "name": "limit",
                        "in": "query",
                        "schema": {"type": "integer", "default": 10, "maximum": 50},
                    },
                ],
                "responses": {"200": {"description": "Matching messages"}},
            }
        },
        "/mail/message": {
            "get": {
                "operationId": "read_mail",
                "summary": "Read one e-mail by uid",
                "parameters": [
                    {
                        "name": "uid",
                        "in": "query",
                        "required": True,
                        "schema": {"type": "string"},
                    },
                    {
                        "name": "mailbox",
                        "in": "query",
                        "schema": {"type": "string", "default": "INBOX"},
                    },
                ],
                "responses": {"200": {"description": "Message headers and text body"}},
            }
        },
        "/mail/mailboxes": {
            "get": {
                "operationId": "list_mailboxes",
                "summary": "List the mailbox folders of the logged-in user",
                "responses": {"200": {"description": "Mailbox names"}},
            }
        },
    },
}


class Handler(BaseHTTPRequestHandler):
    server_version = "mail-api/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write(
            "%s %s\n" % (self.address_string(), fmt % args)
        )

    def _peer_allowed(self) -> bool:
        try:
            peer = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        return any(peer in net for net in ALLOWED_NETS)

    def _send(self, status: int, payload) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._peer_allowed():
            return self._send(403, {"error": "forbidden"})

        parsed = urlparse(self.path)
        if parsed.path == "/openapi.json":
            return self._send(200, SPEC)
        if parsed.path == "/health":
            return self._send(200, {"status": "ok"})

        user = (self.headers.get("X-OpenWebUI-User-Email") or "").strip().lower()
        if not USER_RE.match(user):
            return self._send(401, {"error": "missing or invalid user header"})

        params = parse_qs(parsed.query)
        try:
            limit = int((params.get("limit") or [DEFAULT_LIMIT])[0])
        except ValueError:
            return self._send(400, {"error": "invalid limit"})
        limit = max(1, min(limit, MAX_LIMIT))
        mailbox = (params.get("mailbox") or ["INBOX"])[0]

        try:
            if parsed.path == "/mail/recent":
                return self._send(200, {"messages": list_recent(user, mailbox, limit)})
            if parsed.path == "/mail/search":
                query = (params.get("query") or [""])[0].strip()
                if not query:
                    return self._send(400, {"error": "query is required"})
                return self._send(
                    200, {"messages": search(user, mailbox, query, limit)}
                )
            if parsed.path == "/mail/message":
                uid = (params.get("uid") or [""])[0]
                if not uid:
                    return self._send(400, {"error": "uid is required"})
                return self._send(
                    200, {"message": read_message(user, mailbox, uid)}
                )
            if parsed.path == "/mail/mailboxes":
                return self._send(200, {"mailboxes": mailboxes(user)})
            return self._send(404, {"error": "not found"})
        except ValueError as exc:
            return self._send(400, {"error": str(exc)})
        except LookupError as exc:
            return self._send(404, {"error": str(exc)})
        except imaplib.IMAP4.error:
            return self._send(502, {"error": "mailbox unavailable"})
        except Exception as exc:
            sys.stderr.write("mail-api error: %r\n" % (exc,))
            return self._send(500, {"error": "internal error"})


def main():
    server = ThreadingHTTPServer((ADDR, PORT), Handler)
    sys.stderr.write("mail-api listening on %s:%d\n" % (ADDR, PORT))
    server.serve_forever()


if __name__ == "__main__":
    main()
