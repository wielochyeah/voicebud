"""Stands in for llm_worker.py in tests: same protocol, no model. Cleanup drops "ähm, ",
prompt mode answers with a two-section prompt. --crash exits on the first request.
--queue S waits S seconds before taking a request ("started"), --gen S after it; --log FILE writes
every op it gets (op and the first 40 characters of each system prompt)."""
import json
import re
import sys
import time


def arg(name, default=0.0):
    return float(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


crash = "--crash" in sys.argv
queue_s, gen_s = arg("--queue"), arg("--gen")
log = open(sys.argv[sys.argv.index("--log") + 1], "a") if "--log" in sys.argv else None
print(json.dumps({"event": "ready", "load_s": 0.01}), flush=True)
for line in sys.stdin:
    req = json.loads(line)
    if log:
        log.write(json.dumps({"op": req.get("op"), "systems": [s[:40] for s in req.get("systems", [])]}) + "\n")
        log.flush()
    if req.get("op") == "quit":
        break
    if req.get("op") != "generate":
        continue
    if crash:
        sys.exit(3)
    time.sleep(queue_s)
    print(json.dumps({"event": "started", "id": req["id"]}), flush=True)
    time.sleep(gen_s)
    m = re.search(r"<transkript>\n(.*)\n</transkript>", req["user"], re.S)
    text = m.group(1).replace("ähm, ", "").replace("Ähm, ", "") if m else "Rolle: Coach\n\nAufgabe: Plan"
    if m:
        text = text[:1].upper() + text[1:]
    print(json.dumps({"id": req["id"], "text": text, "stats": {"tokens": len(text.split())}}), flush=True)
