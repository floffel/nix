"""Render the retired Wiki.js sqlite database into INSERTs for the new postgres DB.

One-off migration tool, kept as the reproducible record of how the pages moved off
saver CT 107 on 2026-11-23; see ../nixwikijs/README.md for the verification.

Usage: wikijs-sqlite-import.py <db.sqlite> <pgcols.txt> <out.sql>

pgcols.txt is "table|column|data_type|is_nullable|column_default" as produced by
an information_schema query on the target database. Only columns that exist on
both sides are written, so a newer Wiki.js schema (extra columns) is tolerated.
"""
import sqlite3, sys, json

db, colf, out = sys.argv[1], sys.argv[2], sys.argv[3]

pg = {}
for line in open(colf):
    parts = line.rstrip("\n").split("|")
    if len(parts) < 5:
        continue
    pg.setdefault(parts[0], {})[parts[1]] = (parts[2], parts[3], parts[4])

# order matters: FK targets first
TABLES = ["locales", "assetFolders", "pages", "pageHistory", "pageTree",
          "assets", "assetData", "navigation"]
EXTRA = [("userGroups", ['INSERT INTO "userGroups" ("userId", "groupId") VALUES (3, 1);'])]
UPSERT = {"navigation": ["key"]}
SETTINGS = ["company", "contentLicense", "editShortcuts", "features", "footerOverride",
            "lang", "logoUrl", "nav", "pageExtensions", "security", "seo", "theming", "title"]

# Deliberately NOT ported: auth (the new box authenticates against Kanidm),
# certs/JWK, host, mail, sessionSecret and telemetry are per-instance.
SKIP_NOTE = "auth/certs/host/mail/sessionSecret/telemetry stay per-instance"


def lit(value, dtype):
    if value is None:
        return "NULL"
    if dtype == "boolean":
        return "TRUE" if value else "FALSE"
    if dtype == "bytea":
        return "'\\x%s'::bytea" % value.hex()
    if dtype in ("json", "jsonb"):
        if not isinstance(value, str):
            value = json.dumps(value)
        return "'%s'::%s" % (value.replace("'", "''"), dtype)
    if dtype in ("integer", "bigint", "smallint", "numeric", "real", "double precision"):
        return str(int(value)) if float(value) == int(value) else str(value)
    return "'%s'" % str(value).replace("'", "''")


con = sqlite3.connect(db)
con.text_factory = bytes
w = ["BEGIN;", "SET client_min_messages = warning;"]

for t in TABLES:
    if t not in pg:
        sys.exit("no such target table: " + t)
    cols = [r[1].decode() if isinstance(r[1], bytes) else r[1]
            for r in con.execute('PRAGMA table_info("%s")' % t)]
    tgt = [c for c in cols if c in pg[t]]
    missing = [c for c, (dt, nl, dflt) in pg[t].items()
               if nl == "NO" and dflt == "-" and c not in tgt]
    if missing:
        sys.exit("%s: NOT NULL columns absent from sqlite: %s" % (t, missing))
    rows = list(con.execute('SELECT %s FROM "%s"' % (", ".join('"%s"' % c for c in tgt), t))
                )
    if t == "locales":
        rows = [r for r in rows if r[tgt.index("code")] != b"en"]
    sel = []
    for r in rows:
        vals = []
        for c, v in zip(tgt, r):
            dt = pg[t][c][0]
            if dt != "bytea" and isinstance(v, bytes):
                v = v.decode("utf-8", "surrogateescape")
            if dt == "bytea" and not isinstance(v, bytes):
                v = bytes(v, "latin-1")
            if v is None and pg[t][c][1] == "NO" and pg[t][c][2] == "-":
                sys.exit("%s.%s is NULL but required" % (t, c))
            vals.append(lit(v, dt))
        sel.append("(" + ", ".join(vals) + ")")
    w.append("-- %s: %d rows" % (t, len(sel)))
    if sel:
        stmt = 'INSERT INTO "%s" (%s) VALUES\n%s' % (
            t, ", ".join('"%s"' % c for c in tgt), ",\n".join(sel))
        if t in UPSERT:
            # The new install already seeded these single-row config tables with
            # defaults; the retired box holds the user's own configuration.
            stmt += ("\nON CONFLICT (%s) DO UPDATE SET %s;"
                     % (", ".join('"%s"' % c for c in UPSERT[t]),
                        ", ".join('%s = EXCLUDED.%s' % (c, c)
                                  for c in tgt if c not in UPSERT[t])))
        else:
            stmt += ";"
        w.append(stmt)

for _t, stmts in EXTRA:
    w.append("-- userGroups: delta")
    w.extend(stmts)

sc = pg["settings"]
vals = []
for k, v, u in con.execute("SELECT key, value, updatedAt FROM settings"):
    k = k.decode()
    if k not in SETTINGS:
        continue
    if isinstance(v, bytes):
        v = v.decode()
    if isinstance(u, bytes):
        u = u.decode()
    vals.append((k, lit(v, sc["value"][0]), lit(u, sc["updatedAt"][0])))
w.append("-- settings: port %d keys (%s)" % (len(vals), SKIP_NOTE))
for k, v, u in vals:
    w.append("INSERT INTO settings (key, value, \"updatedAt\") VALUES ('%s', %s, %s)"
             " ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value,"
             " \"updatedAt\" = EXCLUDED.\"updatedAt\";" % (k, v, u))

for seq, (t, col) in {
    "pages_id_seq": ("pages", "id"),
    "pageHistory_id_seq": ("pageHistory", "id"),
    "assets_id_seq": ("assets", "id"),
    "assetFolders_id_seq": ("assetFolders", "id"),
    "userGroups_id_seq": ("userGroups", "id"),
}.items():
    m = list(con.execute('SELECT COALESCE(MAX("%s"), 1) FROM "%s"' % (col, t)))[0][0]
    w.append('SELECT setval(\'"%s"\', %s, true);' % (seq, m))

w.append("COMMIT;")
open(out, "w").write("\n".join(w) + "\n")
print("wrote %s: %d statements" % (out, len(w)))
