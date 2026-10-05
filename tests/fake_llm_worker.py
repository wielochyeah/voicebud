"""Stands in for llm_worker.py in tests: same protocol, no model. Cleanup drops "ähm, ",
prompt mode answers with a two-section prompt. --crash exits on the first request."""
import json
import re
import sys

crash = "--crash" in sys.argv
print(json.dumps({"event": "ready", "load_s": 0.01}), flush=True)
for line in sys.stdin:
    req = json.loads(line)
    if req.get("op") == "quit":
        break
    if req.get("op") != "generate":
        continue
    if crash:
        sys.exit(3)
    m = re.search(r"<transkript>\n(.*)\n</transkript>", req["user"], re.S)
    text = m.group(1).replace("ähm, ", "").replace("Ähm, ", "") if m else "Rolle: Coach\n\nAufgabe: Plan"
    if m:
        text = text[:1].upper() + text[1:]
    print(json.dumps({"id": req["id"], "text": text, "stats": {"tokens": len(text.split())}}), flush=True)
