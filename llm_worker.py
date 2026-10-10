"""The local LLM in its own process (MLX). cleanup.Cleaner starts it and talks JSON lines over
stdin/stdout. It exits by itself after --idle seconds without a request, so the model (~2.4 GB)
and its libraries (~130 MB that an in-process unload would leave behind) leave RAM completely.

Requests:  {"op": "generate", "id": n, "system": str, "user": str, "max_tokens": n, "temp": t,
            "loop_guard": bool}
           {"op": "prefill", "systems": [str]}  cache these system prompts now (below every request)
           {"op": "touch"}                      restart the idle clock
           {"op": "keep", "value": bool}     stay loaded (settings keepModelsLoaded)
           {"op": "vision"}                     get the formula reader ready (⌥ tapped in ⇧⌘2)
           {"op": "formula", "id": n, "image": path}   read a screen region (formula.py)
           {"op": "quit"}
Events:    {"event": "ready", "load_s": s} | {"event": "error", "error": str}
           {"event": "started", "id": n}        a generate request leaves the queue (its clock starts)
           {"id": n, "text": str, "stats": {...}} | {"id": n, "error": str}

The system prompt of each request is prefilled once and kept as a prompt cache (a few, most
recent first), so a take only prefills its own transcript.

--lookahead auto|on|off (config llm.lookahead): lookahead decoding (lookahead.py), prompt-lookup
speculative decoding for greedy requests, same text bit for bit. auto = M1-M4 only, after a one-time
check per machine in idle time that it is identical and faster; on = anywhere (still checked).

Formulas (05.10.): the same Qwen3.5 checkpoint has a vision part. It is built on the first formula
request around the language weights already loaded here (the very same arrays, measured: +0.67 GB
instead of a second 3 GB copy) and dropped again after --idle seconds without a formula, so a
worker kept loaded for dictation does not keep it. The dictation path never touches it."""
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
FORMULA_SIDE = 1000   # longest image side for the formula reader (measured 05.10.: 1.4-2.8 s, exact)
FORMULA_PROMPT = ("Transcribe all text in this image exactly as written, in its original language. "
                  "Write every mathematical expression in LaTeX: inline as $...$, a formula on its own "
                  "line as $$...$$. Keep headings, paragraphs and bold text in Markdown; write bullet "
                  "lists as '- ' lines. Output only the transcription.")


def _sysctl(name):
    """A sysctl string, read in-process (no subprocess, no PATH); "" if unreadable."""
    try:
        import ctypes
        f = ctypes.CDLL(None).sysctlbyname
        f.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
                      ctypes.c_size_t]
        f.restype = ctypes.c_int
        size = ctypes.c_size_t(0)
        if f(name.encode(), None, ctypes.byref(size), None, 0) != 0 or not size.value:
            return ""
        buf = ctypes.create_string_buffer(size.value)
        if f(name.encode(), buf, ctypes.byref(size), None, 0) != 0:
            return ""
        return buf.value.decode("utf-8", "replace").strip()
    except Exception:
        return ""


def _chip_gen(brand):
    """1 for "Apple M1 Pro", 5 for "Apple M5 Pro", None for anything else."""
    import re
    m = re.match(r"Apple M(\d+)\b", brand or "")
    return int(m.group(1)) if m else None


def _one_line(text, limit=200):
    """An error for the log: its first line only (a Metal compiler error runs over many)."""
    lines = str(text).strip().splitlines() or [""]
    return lines[0][:limit]


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


def readahead_ranges(path, skip=("vision_tower",)):
    """Byte ranges of a safetensors file worth reading ahead: every tensor but the vision part (not
    used for dictation), merged where the gap is under 1 MiB, each at most 1 GiB. Empty on any doubt."""
    import struct
    try:
        with open(path, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            if not 0 < n < 64 * 2**20:
                return []
            header = json.loads(f.read(n))
        size = os.path.getsize(path)
        base = 8 + n
        spans = sorted((base + t["data_offsets"][0], base + t["data_offsets"][1])
                       for name, t in header.items()
                       if name != "__metadata__" and not any(name.startswith(s) or f".{s}" in name for s in skip))
    except Exception:
        return []
    merged = []
    for a, b in spans:
        if b <= a or b > size:
            continue
        if merged and a - merged[-1][1] < 2**20:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    out = []
    for a, b in merged:
        while a < b:
            out.append((a, min(b, a + 2**30)))
            a = out[-1][1]
    return out


def readahead(folder):
    """Ask macOS to read the model's language weights into the file cache while Python imports its
    libraries (10.10.: after the idle exit a 16 GB Mac has often dropped them, and the load then read
    2.2 GB only after the imports). Same bytes either way; it never blocks the worker and any error
    leaves the load as it was. F_RDADVISE = 44, struct radvisory {off_t offset; int count;}."""
    import fcntl
    import struct
    try:
        for path in sorted(os.path.join(folder, n) for n in os.listdir(folder) if n.endswith(".safetensors")):
            fd = os.open(path, os.O_RDONLY)
            try:
                for a, b in readahead_ranges(path):
                    fcntl.fcntl(fd, 44, struct.pack("=qi4x", a, b - a))
            finally:
                os.close(fd)
    except Exception as e:
        print(f"readahead skipped ({type(e).__name__}: {e})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--idle", type=float, default=300.0)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--lookahead", "--speculative", dest="lookahead", choices=("auto", "on", "off"),
                    default="auto")
    ap.add_argument("--readahead", default="", help="the model's folder: its weights are read ahead")
    args = ap.parse_args()
    if args.readahead:            # first of all, so the disk works while the libraries import
        threading.Thread(target=readahead, args=(args.readahead,), name="readahead", daemon=True).start()

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

    # lookahead decoding (lookahead.py). auto = M1-M4 only; M5 and newer stay off so the owner's M5 Pro
    # runs exactly as before (it measured 1.2x faster forced on), and an unknown chip stays off; neither
    # ever imports lookahead.py. on = anywhere, to test it. Before it is used on a machine a one-time
    # check (remembered per chip, macOS build, MLX versions, model and code) runs in idle time: a
    # bit-for-bit self-test and a fixed take through both paths, timed. Any difference, error or crash
    # keeps it off on that machine, and auto also needs the take to be at least 8% faster.
    la = {"on": False, "decided": args.lookahead == "off", "mod": None, "key": None, "seen": None,
          "vouched": False, "tested": None}
    brand = _sysctl("machdep.cpu.brand_string") if args.lookahead != "off" else ""
    if args.lookahead == "auto" and not 1 <= (_chip_gen(brand) or 0) <= 4:
        la["decided"] = True
        print(f"lookahead decoding off (auto, {brand or 'unknown chip'})")

    def la_key(mod):
        """The machine key, or "" when the chip or macOS build cannot be read (then nothing is kept)."""
        if la["key"] is None:
            os_build = _sysctl("kern.osversion")
            la["key"] = mod.machine_key(model, args.model, brand, os_build) if brand and os_build else ""
        return la["key"]

    def la_failed(why):
        """Plain decoding for the rest of this process, and remembered for this machine."""
        la.update(on=False, decided=True)
        try:
            import lookahead
            lookahead.uninstall()
            if la_key(lookahead):
                lookahead.remember(la["key"], {"exact": False, "reason": _one_line(why)})
        except Exception:
            pass

    def la_check(abort):
        """The bit-for-bit self-test, then the fixed takes plain, lookahead, lookahead, plain (same
        tokens every time; the worse of the two speed ratios counts). None if a request came in."""
        import lookahead
        if not lookahead.supported(model, make_prompt_cache(model)):
            return {"exact": False, "reason": "model caches not supported"}
        lookahead.install()
        la["mod"] = lookahead
        t = time.time()
        if la["tested"] is None:           # a check resumed after giving way skips a passed self-test
            exact, step = lookahead.self_test(model, tok, lambda: make_prompt_cache(model),
                                              make_sampler(temp=0.0), abort)
            if exact is None:
                return None
            la["tested"] = (exact, step)
        exact, step = la["tested"]
        tps = round(1 / max(step, 1e-6))
        if not exact:
            return {"exact": False, "reason": "checking pass not bit-identical", "tps": tps}
        system = next(iter(prefixes)) if prefixes else "Schreib den Text sauber ab."
        first, runs = {}, []
        for use in (False, True, True, False):
            secs = 0.0
            for text in lookahead.CANNED:
                if abort and abort():
                    return None
                req = {"id": None, "system": system, "user": f"<transkript>\n{text}\n</transkript>",
                       "max_tokens": int(len(text) * 0.6) + 64, "temp": 0.0}
                out, stats, toks = generate(req, use_spec=use, abort=abort, strict=True)
                if stats["cancelled"]:
                    return None
                if first.setdefault(text, (out, toks)) != (out, toks):
                    return {"exact": False, "reason": "canned take differs", "tps": tps}
                secs += stats["eval"]
            runs.append(round(secs, 3))
        ratio = max(runs[1] / max(runs[0], 1e-6), runs[2] / max(runs[3], 1e-6))
        return {"exact": True, "reason": "", "tps": tps, "tokens": sum(len(v[1]) for v in first.values()),
                "plain_s": [runs[0], runs[3]], "lookahead_s": [runs[1], runs[2]], "ratio": round(ratio, 3),
                "fast": ratio <= 0.92, "check_s": round(time.time() - t, 2)}

    def la_decide(abort):
        """Once per process, from the main loop after 30 s without a request; gives way to one."""
        if la["decided"]:
            return
        try:
            import lookahead
            key = la_key(lookahead)
            seen = lookahead.remembered(key) if key else None
            fresh = seen is None
            if fresh:
                if key:      # a crash inside the check leaves this behind: off on the next start
                    lookahead.remember(key, {"exact": False, "reason": "check did not finish"})
                seen = la_check(abort)
                if seen is None:                   # gave way to a request: not done, not failed
                    lookahead.uninstall()
                    if key:
                        lookahead.forget(key)
                    return
                if key:
                    lookahead.remember(key, seen)
            la["decided"], la["seen"] = True, seen
            la["on"] = bool(seen.get("exact")) and (args.lookahead == "on" or bool(seen.get("fast")))
            if la["on"]:
                lookahead.install()
                la["mod"] = lookahead
            else:
                lookahead.uninstall()
            if not seen.get("exact"):
                verdict = f"failed: {seen.get('reason')}"
            else:
                verdict = f"identical, {seen.get('ratio')} of the plain time" + (
                    "" if seen.get("fast") else ", under 8% faster: off on auto")
            print(f"lookahead decoding {'on' if la['on'] else 'off'} ({args.lookahead}, {brand}; "
                  f"check {'now' if fresh else 'of ' + str(seen.get('checked'))}: {verdict})")
        except Exception as e:     # a kernel that does not compile, another MLX: plain decoding
            la_failed(f"{type(e).__name__}: {e}")
            print(f"lookahead decoding off ({_one_line(f'{type(e).__name__}: {e}')})")

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

    def generate(req, use_spec=None, abort=None, strict=False):
        """(text, stats, tokens). use_spec None: as decided for this process (undecided = plain; the
        check never holds up a take). A lookahead run that fails in any way is done again plainly
        (one log line, plain from then on); strict (the check) lets the error through instead."""
        (pids, pcache), prefix_s = prefix(req["system"])
        ids = tok.encode(chat(req["system"], req["user"]))
        temp = float(req.get("temp", 0.0))
        if use_spec is None:      # greedy only (sampling draws would not line up), short contexts only
            use_spec = la["on"] and temp == 0.0 and len(ids) < la["mod"].MAX_CONTEXT
        if not use_spec:
            return run(req, pids, pcache, ids, temp, prefix_s, False, abort)
        vouch = not strict and not la["vouched"] and bool(la["key"])
        if vouch:     # the first lookahead take of a process: a crash in it leaves this behind
            la["mod"].remember(la["key"], {"exact": False, "reason": "lookahead run did not finish"})
        try:
            out = run(req, pids, pcache, ids, temp, prefix_s, True, abort)
        except Exception as e:
            if strict:
                raise
            la_failed(f"{type(e).__name__}: {e}")
            print(f"lookahead decoding failed ({_one_line(f'{type(e).__name__}: {e}')}); plain decoding from now on")
            return run(req, pids, pcache, ids, temp, prefix_s, False, abort)
        if vouch:
            la["mod"].remember(la["key"], la["seen"])      # the passed check again, with its own date
            la["vouched"] = True
        return out

    def run(req, pids, pcache, ids, temp, prefix_s, use_spec, abort):
        if ids[:len(pids)] == pids:
            cache, feed = copy.deepcopy(pcache), ids[len(pids):]
        else:                     # the template tokenised across the boundary: no shortcut
            cache, feed = make_prompt_cache(model), ids
        sampler = make_sampler(temp=temp)
        sstats = None
        if use_spec:
            # guesses come from the user part of the prompt (the transcript, the selection)
            sstats = {}
            steps = la["mod"].stream_generate(model, tok, feed, int(req.get("max_tokens", 256)), sampler,
                                              cache, feed, sstats)
        else:
            # prefill_step_size: mlx-lm's default today, pinned because lookahead.PREFILL_STEP must match
            # it (another split changes the cache bits); not imported, M5+ never loads lookahead.py
            steps = stream_generate(model, tok, feed, max_tokens=int(req.get("max_tokens", 256)),
                                    sampler=sampler, prompt_cache=cache, prefill_step_size=2048)
        t, text, last, toks, looped, stopped = time.time(), "", None, [], False, False
        for r in steps:
            text += r.text
            last = r
            toks.append(r.token)
            if req.get("id") in cancelled or (abort and abort()):   # no longer needed
                stopped = True
                break
            if req.get("loop_guard") and len(toks) >= 3 * LOOP_WINDOW and len(toks) % 8 == 0 and _looping(toks):
                looped = True
                break
        if hasattr(steps, "close"):
            steps.close()
        total = time.time() - t
        prompt_s = (last.prompt_tokens / last.prompt_tps) if last and last.prompt_tps else 0.0
        stats = {"prefix": round(prefix_s, 3), "prompt": round(prompt_s, 3),
                 "eval": round(max(0.0, total - prompt_s), 3),
                 "tokens": last.generation_tokens if last else 0,
                 "cached": len(feed) < len(ids), "looped": looped, "cancelled": stopped}
        if sstats is not None:
            stats.update(sstats)        # passes (forward passes), proposed and accepted guesses
        return text, stats, toks

    vision = {"model": None, "processor": None, "last": 0.0}

    def vision_model():
        """The vision model around this process's language weights (see the module comment)."""
        if vision["model"] is None:
            t = time.time()
            from mlx.utils import tree_flatten, tree_unflatten
            from mlx_vlm import load as vlm_load
            vm, processor = vlm_load(args.model, lazy=True)
            vm.update(tree_unflatten(tree_flatten(model.parameters())))   # shared, not copied
            mx.eval(vm.parameters())
            vision.update(model=vm, processor=processor)
            print(f"formula reader ready in {time.time() - t:.2f}s")
        vision["last"] = time.time()
        return vision["model"], vision["processor"]

    def drop_vision():
        if vision["model"] is not None and time.time() - vision["last"] > args.idle:
            vision.update(model=None, processor=None)
            import gc
            gc.collect()
            mx.clear_cache()
            print("formula reader unloaded (idle)")

    def formula(req):
        from PIL import Image
        from mlx_vlm import stream_generate as vlm_stream
        from mlx_vlm.prompt_utils import apply_chat_template
        t0 = time.time()
        vm, processor = vision_model()
        load_s = time.time() - t0
        path = req["image"]
        img = Image.open(path)
        if max(img.size) > FORMULA_SIDE:      # a Retina capture: half the pixels read just as well
            f = FORMULA_SIDE / max(img.size)
            img = img.convert("RGB").resize((max(1, round(img.width * f)), max(1, round(img.height * f))),
                                            Image.LANCZOS)
            path = path[:-4] + "-small.png"
            img.save(path)
        try:
            try:
                prompt = apply_chat_template(processor, vm.config, FORMULA_PROMPT, num_images=1,
                                             enable_thinking=False)
            except TypeError:
                prompt = apply_chat_template(processor, vm.config, FORMULA_PROMPT, num_images=1)
            t, text, last, toks, looped, stopped = time.time(), "", None, [], False, False
            for r in vlm_stream(vm, processor, prompt, image=[path], max_tokens=int(req.get("max_tokens", 1500)),
                                temperature=0.0):
                text += r.text
                last = r
                if r.token is not None:
                    toks.append(r.token)
                if req.get("id") in cancelled:
                    stopped = True
                    break
                if len(toks) >= 3 * LOOP_WINDOW and len(toks) % 8 == 0 and _looping(toks):
                    looped = True
                    break
        finally:
            if path != req["image"]:
                try:
                    os.remove(path)
                except OSError:
                    pass
        return text, {"vision_load": round(load_s, 3), "eval": round(time.time() - t, 3),
                      "tokens": last.generation_tokens if last else 0, "looped": looped, "cancelled": stopped}

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
            if req.get("op") in ("generate", "formula"):
                if req.get("spec"):
                    spec_ids.add(req.get("id"))
                else:
                    cancelled.update(spec_ids)
            # a system prompt computed ahead comes after every request, one prompt per item: a take
            # waits for the prompt being computed, never for the rest of the list (10.10.: on an M1
            # all four took ~15 s, and a short take after a pause waited behind all of them)
            prio = 2 if req.get("op") == "prefill" else 1 if req.get("spec") else 0
            inbox.put((prio, next(order), req))
        inbox.put((0, next(order), {"op": "quit"}))
    threading.Thread(target=reader, name="stdin", daemon=True).start()

    last_op = time.time()
    while True:
        drop_vision()                 # unused for --idle: the formula reader goes (the dictation model stays)
        try:
            req = inbox.get(timeout=5)[2]
        except queue.Empty:
            # the lookahead check only after 30 s without any request (not while the user speaks:
            # a key press sends "touch"), and it gives way to the next one; the idle exit still
            # counts from the last request
            if not la["decided"] and time.time() - last_op >= 30:
                state["busy"] = True
                try:
                    la_decide(abort=lambda: not inbox.empty())
                finally:
                    mx.clear_cache()
                    state["busy"] = False
            continue
        last_op = time.time()
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
        if op == "formula" and req.get("id") in cancelled:     # the core gave up on it while it waited
            send({"id": req.get("id"), "cancelled": True})
            continue
        if op in ("vision", "formula"):
            state["busy"] = True
            try:
                if op == "vision":
                    vision_model()
                else:
                    text, stats = formula(req)
                    send({"id": req.get("id"), "cancelled": True} if stats.get("cancelled")
                         else {"id": req.get("id"), "text": text, "stats": stats})
            except Exception as e:
                print(f"formula failed: {e!r}")
                if op == "formula":
                    send({"id": req.get("id"), "error": f"{type(e).__name__}: {e}"})
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
        send({"event": "started", "id": req.get("id")})
        try:
            text, stats, _ = generate(req)
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
