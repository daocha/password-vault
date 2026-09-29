#!/usr/bin/env python3
"""Prints the STRUCTURE of a Password Keeper CSV with every value masked, so it can be shared safely.

    scripts/inspect-csv.py /path/to/backup.csv [record name]

Shows, per record, the non-empty columns (value replaced by its length) and, for `customFields`, the
JSON layout with each string replaced by <str N>. With a record name it only shows matching records.
"""
import csv, json, sys

def mask(o):
    if isinstance(o, dict): return {k: mask(v) for k, v in o.items()}
    if isinstance(o, list): return [mask(v) for v in o]
    if isinstance(o, str): return f"<str {len(o)}>"
    return o

if len(sys.argv) < 2: sys.exit(__doc__)
want = sys.argv[2].lower() if len(sys.argv) > 2 else None
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8-sig", newline="")))
print(f"{len(rows)} records; columns: {list(rows[0].keys()) if rows else []}")
shown = 0
for i, r in enumerate(rows):
    if want and want not in (r.get("name") or "").lower(): continue
    custom = r.get("customFields") or ""
    if not want and (not custom or custom == "[]"): continue   # by default only records that use custom fields
    shown += 1
    print(f"\n--- record {i}: name is {len(r.get('name') or '')} chars")
    for k, v in r.items():
        if k == "customFields": continue
        if v: print(f"  {k}: " + (v if k in ("fav", "flags", "imageIndex", "dataVersion", "usernameLabel", "passwordLabel", "websiteLabel", "notesLabel") else f"<{len(v)} chars>"))
    if custom:
        try: print("  customFields (JSON):", json.dumps(mask(json.loads(custom)), indent=2))
        except ValueError: print(f"  customFields (NOT JSON): {len(custom)} chars, starts with {custom[:1]!r}, separators: {sorted({c for c in custom if not c.isalnum()})[:12]}")
if not shown: print("No matching records with custom fields.")
