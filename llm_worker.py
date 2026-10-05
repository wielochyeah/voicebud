"""The local LLM in its own process (MLX). cleanup.Cleaner starts it and talks JSON lines over
stdin/stdout. It exits by itself after --idle seconds without a request, so the model (~2.4 GB)
and its libraries (~130 MB that an in-process unload would leave behind) leave RAM completely.

Requests:  {"op": "generate", "id": n, "system": str, "user": str, "max_tokens": n, "temp": t,
            "loop_guard": bool}
           {"op": "prefill", "systems": [str]}  cache these system prompts now
           {"op": "touch"}                      restart the idle clock
           {"op": "keep", "value": bool}     stay loaded (settings keepModelsLoaded)
           {"op": "quit"}
Events:    {"event": "ready", "load_s": s} | {"event": "error", "error": str}
           {"id": n, "text": str, "stats": {...}} | {"id": n, "error": str}

The system prompt of each request is prefilled once and kept as a prompt cache (a few, most
recent first), so a take only prefills its own transcript."""
import argparse
import copy
import itertools
import json
import os
import queue
import sys
import threading
import time
from collections import OrderedDict

MARK = "⁣VBMARK⁣"
MAX_PREFIXES = 4
LOOP_WINDOW = 12      # loop_guard: stop when the last 12 tokens already ran twice before


def _looping(toks):
    """The newest LOOP_WINDOW tokens already appear twice earlier: the model repeats itself."""
    tail = toks[-LOOP_WINDOW:]
    hits, i = 0, 0
    while i <= len(toks) - 2 * LOOP_WINDOW:
        if toks[i:i + LOOP_WINDOW] == tail:
            hits += 1
            i += LOOP_WINDOW
        else:
            i += 1
    return hits >= 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--idle", type=float, default=300.0)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    proto = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)                 # whatever a library prints goes to the log, never into the protocol
    sys.stdout = sys.stderr
    lock = threading.Lock()

    def send(obj):
        with lock:
            proto.write(json.dumps(obj, ensure_ascii=False) + "\n")
            proto.flush()

    state = {"keep": args.keep, "last": time.time(), "busy": False}
    cancelled = set()

    def watchdog():
        while True:
            time.sleep(5)
            if not state["keep"] and not state["busy"] and time.time() - state["last"] > args.idle:
                os._exit(0)
    threading.Thread(target=watchdog, daemon=True).start()

    t0 = time.time()
    try:
        import mlx.core as mx
        mx.set_cache_limit(64 * 1024 * 1024)
        from mlx_lm import load, stream_generate
        from mlx_lm.models.cache import make_prompt_cache
        from mlx_lm.sample_utils import make_sampler
        model, tok = load(args.model)
    except Exception as e:  # missing model files, broken install
        send({"event": "error", "error": f"{type(e).__name__}: {e}"})
        return 1
    send({"event": "ready", "load_s": round(time.time() - t0, 2)})
    state["last"] = time.time()
    prefixes = OrderedDict()

    def chat(system, user):
        msgs = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        try:
            return tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False,
                                           enable_thinking=False)
        except TypeError:
            return tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)

    def prefix(system):
        if system in prefixes:
            prefixes.move_to_end(system)
            return prefixes[system], 0.0
        t = time.time()
        probe = chat(system, MARK)
        ids = tok.encode(probe[:probe.index(MARK)])
        cache = make_prompt_cache(model)
        model(mx.array(ids)[None], cache=cache)
        mx.eval([c.state for c in cache])
        prefixes[system] = (ids, cache)
        while len(prefixes) > MAX_PREFIXES:
            prefixes.popitem(last=False)
        return prefixes[system], time.time() - t

    def generate(req):
        (pids, pcache), prefix_s = prefix(req["system"])
        ids = tok.encode(chat(req["system"], req["user"]))
        if ids[:len(pids)] == pids:
            cache, feed = copy.deepcopy(pcache), ids[len(pids):]
        else:                     # the template tokenised across the boundary: no shortcut
            cache, feed = make_prompt_cache(model), ids
        sampler = make_sampler(temp=float(req.get("temp", 0.0)))
        t, text, last, toks, looped, stopped = time.time(), "", None, [], False, False
        for r in stream_generate(model, tok, feed, max_tokens=int(req.get("max_tokens", 256)),
                                 sampler=sampler, prompt_cache=cache):
            text += r.text
            last = r
            toks.append(r.token)
            if req.get("id") in cancelled:     # a speculative request that is no longer needed
                stopped = True
                break
            if req.get("loop_guard") and len(toks) >= 3 * LOOP_WINDOW and len(toks) % 8 == 0 and _looping(toks):
                looped = True
                break
        total = time.time() - t
        prompt_s = (last.prompt_tokens / last.prompt_tps) if last and last.prompt_tps else 0.0
        return text, {"prefix": round(prefix_s, 3), "prompt": round(prompt_s, 3),
                      "eval": round(max(0.0, total - prompt_s), 3),
                      "tokens": last.generation_tokens if last else 0,
                      "cached": len(feed) < len(ids), "looped": looped, "cancelled": stopped}

    # Requests arrive on a reader thread, so a "cancel" reaches a generation that is running.
    # Speculative requests (computed ahead in a speech pause) always yield: a real request cancels
    # the running and queued ones, and they never run before it.
    inbox = queue.PriorityQueue()
    order = itertools.count()
    running = {"id": None, "spec": False}
    spec_ids = set()

    def reader():
        for line in sys.stdin:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            if req.get("op") == "cancel":
                cancelled.add(req.get("id"))
                continue
            if req.get("op") == "generate":
                if req.get("spec"):
                    spec_ids.add(req.get("id"))
                else:
                    cancelled.update(spec_ids)
            inbox.put((1 if req.get("spec") else 0, next(order), req))
        inbox.put((0, next(order), {"op": "quit"}))
    threading.Thread(target=reader, name="stdin", daemon=True).start()

    while True:
        req = inbox.get()[2]
        op = req.get("op")
        if op == "quit":
            break
        if op == "keep":
            state["keep"] = bool(req.get("value"))
            state["last"] = time.time()
            continue
        if op == "touch":                 # the user is speaking: do not exit right now
            state["last"] = time.time()
            continue
        if op == "prefill":
            state["busy"] = True
            try:
                for system in req.get("systems", []):
                    prefix(system)
            except Exception as e:
                print(f"prefill failed: {e!r}")
            finally:
                mx.clear_cache()
                state["busy"] = False
                state["last"] = time.time()
            continue
        if op != "generate":
            continue
        if req.get("id") in cancelled:
            spec_ids.discard(req.get("id"))
            send({"id": req.get("id"), "cancelled": True})
            continue
        state["busy"] = True
        try:
            text, stats = generate(req)
            spec_ids.discard(req.get("id"))
            if stats.get("cancelled"):
                send({"id": req.get("id"), "cancelled": True})
            else:
                send({"id": req.get("id"), "text": text, "stats": stats})
        except Exception as e:
            send({"id": req.get("id"), "error": f"{type(e).__name__}: {e}"})
        finally:
            mx.clear_cache()
            state["busy"] = False
            state["last"] = time.time()
    return 0


if __name__ == "__main__":
    os.environ.setdefault("HF_HUB_OFFLINE", "1")        # local only: never reach the network
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    sys.exit(main())
