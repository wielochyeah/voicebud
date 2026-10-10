"""Lookahead decoding for the cleanup LLM (llm_worker.py): prompt-lookup speculative decoding,
exact by construction. Config llm.lookahead (auto | on | off).

Cleanup mostly copies the transcript, so the next tokens can be guessed from it: the longest tail
(2-4 tokens) of what was generated is looked up in the user part of the prompt and the tokens that
follow it there are proposed. One forward pass checks all of them; every guess the model agrees with
is a decoding step saved. Only for greedy requests (temperature 0) and contexts up to MAX_CONTEXT.

Same text as plain greedy decoding, bit for bit, because the checking pass computes every row exactly
as a one-token step would:
- MLX multiplies a few rows with other kernels than one row (other summation order: logits differ by
  up to 0.5, and an argmax near a tie flips, measured). Here the quantized matmuls of a checking pass
  run a copy of MLX's one-row kernel (qmv_fast) that fetches the weights once for all rows and sums
  each row in exactly the one-row order. A layer the copy does not cover raises (never MLX's
  multi-row path), so such a model fails the check.
- Attention runs per row, with the keys a one-token step at that position sees.
- Qwen3.5's linear-attention layers keep a recurrent state that cannot be cut back after a rejected
  guess. Before each pass the states are kept (references; MLX arrays are immutable); after a
  rejection they are put back, the KV caches are cut to the same point, and the accepted tokens lead
  the next pass (no extra pass, a wider one).
- The prompt is processed in PREFILL_STEP chunks, pinned to the plain path's (a different split
  changes the cache bits).
llm_worker runs a one-time check per machine key (self_test bit for bit, CANNED through both paths,
timed for the speed gate) and falls back to plain decoding on any difference, error or crash.

Measured 10.10. on the M5 Pro (forced on, 99 requests): all outputs identical; decoding 1.21x faster
overall (clean 1.35x, command 1.13x). A checking pass is not free: 2 rows cost 1.15x a one-token pass,
4 rows 1.7x, 6 rows 2.4x (the one-row kernel's arithmetic per row, which exactness forbids changing),
and more at long contexts (each row reads the KV cache), hence MAX_CONTEXT. M1-M4 are not measured;
the speed gate decides per machine.

Metal features of the kernel (all within Apple7 = M1, the oldest family MLX supports): kernel
attributes threadgroup_position_in_grid / simdgroup_index_in_threadgroup / thread_index_in_simdgroup
(MSL 2), simd_sum (SIMD-group reduction, Apple7+; MLX's own qmv_fast uses it on every M1), 8/16-bit
integer loads and masks, float arithmetic, the activation type as a storage type (bfloat for this
model, MSL 3.1, which MLX 0.32's own kernels require anyway; also builds for half and float). No
threadgroup memory, barriers, atomics, simdgroup matrices, neural accelerators or dynamic caching;
64-thread threadgroups and fixed-size register arrays. Compiled at run time by MLX like mlx-lm's
gated-delta kernel that this model already needs."""
import bisect
import os
import time

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.generate import generation_stream
from mlx_lm.models.cache import ArraysCache, KVCache

MAX_NGRAM = 4        # longest history tail looked up in the source
MIN_NGRAM = 2        # shortest tail whose continuation is proposed
DRAFT_START = 2      # guess length at the start; +1 after a full hit, hit + 1 after a miss
DRAFT = 4            # longest guess
WIDTH = 6            # rows per checking pass at most (pending + guess)
NVMAX = 8            # rows per kernel call (registers); more rows take several calls
PREFILL_STEP = 2048  # prompt chunk; must equal prefill_step_size of llm_worker's plain stream_generate
MAX_CONTEXT = 4096   # no guesses beyond this many tokens of context (measured on the M5 Pro: a 4-row
                     # pass costs 1.9x a one-token step at 1k context, 3x at 8k; long takes broke even)

_state = {"exact": False}

# load_vector and qdot from mlx/backend/metal/kernels/quantized.h (MLX 0.32), 4 and 8 bit, verbatim
_HEADER = r"""
template <typename T, typename U, int values_per_thread, int bits>
inline U vb_load_vector(const device T* x, thread U* x_thread) {
  U sum = 0;
  if (bits == 4) {
    for (int i = 0; i < values_per_thread; i += 4) {
      sum += x[i] + x[i + 1] + x[i + 2] + x[i + 3];
      x_thread[i] = x[i];
      x_thread[i + 1] = x[i + 1] / 16.0f;
      x_thread[i + 2] = x[i + 2] / 256.0f;
      x_thread[i + 3] = x[i + 3] / 4096.0f;
    }
  } else if (bits == 8) {
    for (int i = 0; i < values_per_thread; i++) {
      sum += x[i];
      x_thread[i] = x[i];
    }
  }
  return sum;
}

template <typename U, int values_per_thread, int bits>
inline U vb_qdot(const device uint8_t* w, const thread U* x_thread, U scale, U bias, U sum) {
  U accum = 0;
  if (bits == 4) {
    const device uint16_t* ws = (const device uint16_t*)w;
    for (int i = 0; i < (values_per_thread / 4); i++) {
      accum +=
          (x_thread[4 * i] * (ws[i] & 0x000f) +
           x_thread[4 * i + 1] * (ws[i] & 0x00f0) +
           x_thread[4 * i + 2] * (ws[i] & 0x0f00) +
           x_thread[4 * i + 3] * (ws[i] & 0xf000));
    }
  } else if (bits == 8) {
    for (int i = 0; i < values_per_thread; i++) {
      accum += x_thread[i] * w[i];
    }
  }
  return scale * accum + sum * bias;
}
"""

# qmv_fast_impl (same file) for up to NVMAX input rows at once. Each output row is still summed in
# qmv_fast's own order (qdot per 512-value block, blocks in sequence, then simd_sum), so every row is
# bit for bit the one-row result; only the weight fetches are shared by the rows. (Measured 10.10.:
# more output rows per simdgroup, x staged in threadgroup memory or the 4-bit masks taken once per
# block were all bit-exact too, and none was faster.)
_SOURCE = r"""
  constexpr int packs_per_thread = 2;
  constexpr int num_simdgroups = 2;
  constexpr int results_per_simdgroup = 4;
  constexpr int pack_factor = 32 / BITS;
  constexpr int bytes_per_pack = 4;
  constexpr int values_per_thread = pack_factor * packs_per_thread;
  constexpr int block_size = values_per_thread * 32;
  constexpr int scale_step_per_thread = GS / values_per_thread;
  typedef float U;

  uint3 tid = threadgroup_position_in_grid;
  uint simd_gid = simdgroup_index_in_threadgroup;
  uint simd_lid = thread_index_in_simdgroup;
  const int in_vec_size = K;
  const int out_vec_size = N;
  const int nv = NV;

  thread U x_thread[values_per_thread];
  thread U result[NVMAX][results_per_simdgroup];
  for (int v = 0; v < NVMAX; v++)
    for (int r = 0; r < results_per_simdgroup; r++) result[v][r] = 0;

  const int in_vec_size_w = in_vec_size * bytes_per_pack / pack_factor;
  const int in_vec_size_g = in_vec_size / GS;
  const int out_row = tid.y * (num_simdgroups * results_per_simdgroup) + simd_gid * results_per_simdgroup;

  const device uint8_t* ws = (const device uint8_t*)w + out_row * in_vec_size_w + simd_lid * packs_per_thread * bytes_per_pack;
  const device T* sc = scales + out_row * in_vec_size_g + simd_lid / scale_step_per_thread;
  const device T* bi = biases + out_row * in_vec_size_g + simd_lid / scale_step_per_thread;
  const device T* xp = x + simd_lid * values_per_thread;

  for (int k = 0; k < in_vec_size; k += block_size) {
    for (int v = 0; v < nv; v++) {
      U sum = vb_load_vector<T, U, values_per_thread, BITS>(xp + v * in_vec_size, x_thread);
      for (int row = 0; row < results_per_simdgroup; row++) {
        auto wl = (const device uint8_t*)(ws + row * in_vec_size_w);
        U s = sc[row * in_vec_size_g];
        U b = bi[row * in_vec_size_g];
        result[v][row] += vb_qdot<U, values_per_thread, BITS>(wl, x_thread, s, b, sum);
      }
    }
    ws += block_size * bytes_per_pack / pack_factor;
    sc += block_size / GS;
    bi += block_size / GS;
    xp += block_size;
  }
  for (int v = 0; v < nv; v++) {
    for (int row = 0; row < results_per_simdgroup; row++) {
      U r = simd_sum(result[v][row]);
      if (simd_lid == 0) {
        y[v * out_vec_size + out_row + row] = static_cast<T>(r);
      }
    }
  }
"""

_kernel = None


def _rows(x):
    n = 1
    for d in x.shape[:-1]:
        n *= d
    return n


def _exact_ok(m, x):
    """This layer's one-row product is MLX's qmv_fast, which the kernel copies."""
    if getattr(m, "mode", "affine") != "affine" or m.bits not in (4, 8) or m.get("biases") is None:
        return False
    k = x.shape[-1]
    vpt = 2 * 32 // m.bits
    return (k % (vpt * 32) == 0 and m.group_size % vpt == 0 and m["weight"].shape[0] % 8 == 0
            and x.dtype in (mx.bfloat16, mx.float16, mx.float32) and m["scales"].dtype == x.dtype)


def _qmv_rows(m, x):
    """x @ dequantized(m)^T for 2..WIDTH rows, each row exactly as MLX computes a single row."""
    global _kernel
    if _kernel is None:
        _kernel = mx.fast.metal_kernel(name="vb_qmv_rows", input_names=["x", "w", "scales", "biases", "K", "N", "NV"],
                                       output_names=["y"], source=_SOURCE, header=_HEADER)
    k, n, rows = x.shape[-1], m["weight"].shape[0], _rows(x)
    xs = x.reshape(rows, k)
    parts = []
    for i in range(0, rows, NVMAX):
        nv = min(NVMAX, rows - i)
        parts.append(_kernel(inputs=[xs[i:i + nv], m["weight"], m["scales"], m["biases"], k, n, nv],
                             template=[("T", x.dtype), ("NVMAX", NVMAX), ("GS", m.group_size), ("BITS", m.bits)],
                             grid=(32, 2 * (n // 8), 1), threadgroup=(32, 2, 1),
                             output_shapes=[(nv, n)], output_dtypes=[x.dtype])[0])
    y = parts[0] if len(parts) == 1 else mx.concatenate(parts, axis=0)
    return y.reshape(*x.shape[:-1], n)


def _install():
    """Route the products and the attention of a checking pass through the exact paths. Outside
    a checking pass every call goes to MLX unchanged."""
    if getattr(nn.QuantizedLinear, "_vb_exact", False):
        return
    from mlx_lm.models import qwen3_next

    linear_call = nn.QuantizedLinear.__call__
    as_linear = nn.QuantizedEmbedding.as_linear
    sdpa = qwen3_next.scaled_dot_product_attention

    def covered(m, x):
        if not _exact_ok(m, x):     # MLX's multi-row path would not be row-exact
            raise RuntimeError(f"no exact kernel for {type(m).__name__} {tuple(m['weight'].shape)} bits {m.bits}")
        return True

    def linear_exact(self, x):
        if _state["exact"] and _rows(x) > 1 and covered(self, x):
            y = _qmv_rows(self, x)
            return y + self["bias"] if "bias" in self else y
        return linear_call(self, x)

    def as_linear_exact(self, x):
        if _state["exact"] and _rows(x) > 1 and covered(self, x):
            return _qmv_rows(self, x)
        return as_linear(self, x)

    def sdpa_exact(queries, keys, values, cache, scale, mask, sinks=None):
        T = queries.shape[2]
        if not _state["exact"] or T == 1:
            return sdpa(queries, keys, values, cache=cache, scale=scale, mask=mask, sinks=sinks)
        if hasattr(cache, "bits") or sinks is not None:
            raise RuntimeError("no exact attention for a quantized cache or sinks")
        L = keys.shape[2]       # row j sees the keys a one-token step at its position sees
        return mx.concatenate([mx.fast.scaled_dot_product_attention(
            queries[:, :, j:j + 1], keys[:, :, :L - T + j + 1], values[:, :, :L - T + j + 1],
            scale=scale, mask=None, sinks=None) for j in range(T)], axis=2)

    nn.QuantizedLinear.__call__ = linear_exact
    nn.QuantizedEmbedding.as_linear = as_linear_exact
    qwen3_next.scaled_dot_product_attention = sdpa_exact
    nn.QuantizedLinear._vb_exact = True


def _forward(model, tokens, cache):
    """One pass over `tokens`; with more than one token every row is computed as a one-token step."""
    _state["exact"] = len(tokens) > 1
    try:
        return model(mx.array(tokens)[None], cache=cache)
    finally:
        _state["exact"] = False


def _pick(sampler, logits, row):
    """generate_step's choice for one row: logprobs of a (1, vocab) row, then the sampler."""
    lg = logits[:, row, :]
    return sampler(lg - mx.logsumexp(lg, keepdims=True))


def supported(model, cache):
    """Every cache is a KV cache (trimmable) or an ArraysCache (recurrent: kept and put back)."""
    return all(isinstance(c, (KVCache, ArraysCache)) for c in cache) and hasattr(model, "layers")


class _Lookup:
    """Proposes the tokens that follow the longest tail (1..MAX_NGRAM tokens) of the history in the
    source, preferring the occurrence at or after where the copy left off."""

    def __init__(self, source):
        self.src = list(source)
        self.at = {}
        for n in range(1, MAX_NGRAM + 1):
            for i in range(len(self.src) - n):
                self.at.setdefault(tuple(self.src[i:i + n]), []).append(i + n)
        self.cursor = 0

    def propose(self, history, k):
        if k <= 0:
            return []
        for n in range(min(MAX_NGRAM, len(history)), 0, -1):
            ends = self.at.get(tuple(history[-n:]))
            if not ends:
                continue
            i = bisect.bisect_left(ends, self.cursor)
            end = ends[i] if i < len(ends) else ends[0]
            self.cursor = end
            # a one-token match guesses wrong too often to be worth a wider pass
            return self.src[end:end + k] if n >= MIN_NGRAM else []
        return []

    def advance(self, accepted):
        self.cursor += accepted


def generate_step(model, prompt, cache, sampler, max_tokens, source, stats):
    """Tokens exactly as mlx_lm.generate.generate_step yields them with this greedy sampler; the
    caller stops whenever it likes (the cache is its own copy). stats: passes (forward passes),
    proposed and accepted guesses.

    Without a guess it decodes like generate_step (one token per pass, the next pass queued before
    the current token is read). With one, a checking pass takes the pending tokens plus the guess;
    the guess length grows by one after a full hit and drops to what was hit plus one after a miss."""
    prompt = list(prompt)
    look = _Lookup(source)
    stats.update(passes=0, proposed=0, accepted=0, widths={})    # widths: checking passes by rows
    k = DRAFT_START
    with mx.stream(generation_stream):
        # the prompt exactly as generate_step processes it: all but the last token in PREFILL_STEP chunks
        total, done = len(prompt), 0
        arr = mx.array(prompt)
        while total - done > 1:
            n = min(PREFILL_STEP, total - done - 1)
            model(arr[done:done + n][None], cache=cache)
            mx.eval([c.state for c in cache])
            done += n
            mx.clear_cache()
        recurrent = [c for c in cache if isinstance(c, ArraysCache)]
        kv = [c for c in cache if isinstance(c, KVCache)]

        def short():
            """Room for a checking pass within MAX_CONTEXT (beyond it: plain to the end)."""
            return not kv or kv[0].offset + WIDTH <= MAX_CONTEXT

        pending, history, n_out, carry = [prompt[-1]], [], 0, None
        while n_out < max_tokens:
            if carry is not None:
                guess, carry = carry, None
            elif short():
                guess = look.propose(history, min(k, WIDTH - len(pending), max_tokens - n_out - 1))
            else:
                guess = []
            if not guess and len(pending) == 1:
                # plain decoding until a guess turns up
                y = _pick(sampler, model(mx.array(pending)[None], cache=cache), 0)
                mx.async_eval(y)
                stats["passes"] += 1
                while True:
                    nxt = None
                    if n_out + 1 < max_tokens:
                        nxt = _pick(sampler, model(y[None], cache=cache), 0)
                        mx.async_eval(nxt)
                        stats["passes"] += 1
                    t = y.item()
                    history.append(t)
                    n_out += 1
                    yield t
                    if nxt is None:
                        return
                    if n_out % 256 == 0:
                        mx.clear_cache()
                    # a guess for what follows t: the pass already queued checks its first token
                    g = look.propose(history, min(k + 1, WIDTH, max_tokens - n_out - 1)) if short() else []
                    if g:
                        t2 = nxt.item()
                        history.append(t2)
                        n_out += 1
                        stats["proposed"] += 1
                        hit = t2 == g[0]
                        stats["accepted"] += hit
                        look.advance(int(hit))
                        if hit:
                            carry = g[1:] or None
                        else:
                            k = 1
                        pending = [t2]
                        yield t2
                        break
                    y = nxt
                continue
            feed = pending + guess
            kept = [list(c.cache) for c in recurrent] if guess else None
            logits = _forward(model, feed, cache)
            base = len(pending) - 1
            picks = [_pick(sampler, logits, base + j) for j in range(len(guess) + 1)]
            mx.eval(picks)
            picks = [p.item() for p in picks]
            stats["passes"] += 1
            stats["widths"][str(len(feed))] = stats["widths"].get(str(len(feed)), 0) + 1
            stats["proposed"] += len(guess)
            ok = 0
            while ok < len(guess) and picks[ok] == guess[ok]:
                ok += 1
            stats["accepted"] += ok
            out = picks[:ok + 1]
            if ok == len(guess):
                pending = [out[-1]]
                if guess:
                    k = min(DRAFT, k + 1)
            else:
                # recurrent states cannot be cut back: all caches go back to before this pass and
                # the accepted tokens lead the next one
                for c, arrays in zip(recurrent, kept):
                    c.cache = arrays
                for c in kv:
                    c.trim(len(feed))
                pending = pending + guess[:ok] + [out[-1]]
                k = max(1, ok + 1)
            look.advance(ok)
            for t in out:
                history.append(t)
                n_out += 1
                yield t
                if n_out >= max_tokens:
                    return
            if n_out % 256 < len(out):
                mx.clear_cache()


def self_test(model, tok, prompt_cache_factory, sampler, abort=None):
    """Checking passes of every width give bit for bit the logits of one-token steps, also one after
    a pass that was thrown away and put back (as after a rejection). Returns (ok, s per step), or
    (None, 0) when abort() turned true (a request came in: decided another time)."""
    import copy
    msgs = [{"role": "user", "content": "Bitte schreib den Satz ab: Das Meeting ist morgen um zehn Uhr im großen Raum."}]
    try:
        text = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        text = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
    ids = tok.encode(text)
    n = WIDTH + 1
    stop = abort or (lambda: False)
    with mx.stream(generation_stream):
        if stop():
            return None, 0.0
        base = prompt_cache_factory()
        model(mx.array(ids[:-1])[None], cache=base)
        mx.eval([c.state for c in base])
        one = copy.deepcopy(base)
        seq, ref = [ids[-1]], []
        t0 = time.perf_counter()
        for _ in range(n):
            if stop():
                return None, 0.0
            lg = model(mx.array(seq[-1:])[None], cache=one)
            mx.eval(lg)
            ref.append(lg[0, -1])
            seq.append(_pick(sampler, lg, 0).item())
        per_step = (time.perf_counter() - t0) / n
        ok = True
        for w in range(2, WIDTH + 1):            # every width from the same point
            if stop():
                return None, 0.0
            c = copy.deepcopy(base)
            lg = _forward(model, seq[:w], c)
            mx.eval(lg)
            ok &= all(bool(mx.array_equal(lg[0, j], ref[j]).item()) for j in range(w))
        if stop():
            return None, 0.0
        two = copy.deepcopy(base)                # thrown away, put back, then two passes in a row
        recurrent = [c for c in two if isinstance(c, ArraysCache)]
        kv = [c for c in two if isinstance(c, KVCache)]
        kept = [list(c.cache) for c in recurrent]
        mx.eval(_forward(model, seq[:WIDTH], two))
        for c, arrays in zip(recurrent, kept):
            c.cache = arrays
        for c in kv:
            c.trim(WIDTH)
        a = _forward(model, seq[:3], two)
        b = _forward(model, seq[3:n], two)
        mx.eval(a, b)
        rows = [a[0, j] for j in range(3)] + [b[0, j] for j in range(n - 3)]
        ok &= all(bool(mx.array_equal(r, ref[j]).item()) for j, r in enumerate(rows))
    mx.clear_cache()
    return ok, per_step


# the fixed takes of the one-time check. Together they stand in for real takes in the speed gate
# (M5 Pro: the pair ran at 0.82-0.83 of the plain time, the 99-request mix at 1/1.21 = 0.83; the first
# alone, mostly copied, at 0.67), and they take every path: checking passes of 2 to 6 rows, hits,
# misses, states put back and accepted tokens fed again.
CANNED = (
    "Also ich wollte nochmal kurz über das Projekt sprechen. Wir haben jetzt die ersten Ergebnisse aus der Umfrage, "
    "ähm, und die sehen eigentlich ganz gut aus. Ungefähr 70 % der Teilnehmer sind zufrieden mit dem neuen Prozess, "
    "nein, mit dem neuen Ablauf. Trotzdem sollten wir nochmal über die Details reden, weil ein paar Rückmeldungen "
    "kritisch waren.",
    "ähm also ich wollte nur kurz sagen dass das meeting morgen nicht um zehn sondern ähm um elf uhr ist "
    "und bitte bringt die unterlagen zum projekt mit also die zahlen aus dem dritten quartal und die "
    "präsentation von letzter woche",
)


def machine_key(model, model_name, brand, os_build):
    """What the one-time check holds for: this chip, this macOS build (its Metal compiler), these
    MLX versions, this model (name and a fingerprint of every parameter's name, shape and dtype and
    every quantized layer's bits, group size and mode) and this code (this file and llm_worker.py).
    A change to any of these checks again; the weights' values are not hashed."""
    import hashlib
    import mlx_lm
    from mlx.utils import tree_flatten
    fp = hashlib.sha1()
    for name, a in sorted(tree_flatten(model.parameters()), key=lambda kv: kv[0]):
        fp.update(f"{name}:{tuple(a.shape)}:{a.dtype};".encode())
    for name, m in model.named_modules():
        if hasattr(m, "bits") and hasattr(m, "group_size"):
            fp.update(f"{name}:{m.bits}:{m.group_size}:{getattr(m, 'mode', 'affine')};".encode())
    code = hashlib.sha1()
    for path in (__file__, os.path.join(os.path.dirname(os.path.abspath(__file__)), "llm_worker.py")):
        try:
            code.update(open(path, "rb").read())
        except OSError:
            pass
    return "|".join([brand, os_build, f"mlx {mx.__version__}", f"mlx-lm {mlx_lm.__version__}", model_name,
                     f"model {fp.hexdigest()[:12]}", f"code {code.hexdigest()[:12]}"])


def _memo_path():
    import settings
    return settings.data_dir() / "lookahead.json"


def remembered(key):
    import json
    try:
        return json.loads(_memo_path().read_text()).get(key)
    except (OSError, ValueError, AttributeError):
        return None


def _update(key, result):
    import json
    path = _memo_path()
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    data.pop(key, None)
    if result is not None:
        data[key] = dict(result)
        data[key].setdefault("checked", time.strftime("%Y-%m-%d %H:%M"))
    data = dict(list(data.items())[-8:])
    try:
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
        os.replace(tmp, path)
    except OSError as e:
        print(f"lookahead check not saved: {e}")


def remember(key, result):
    """Kept per machine key (the newest few), so the check runs once, and a failed one never again.
    A result without "checked" gets the time now; a restored one keeps its own."""
    _update(key, result)


def forget(key):
    """A check that gave way to a take: it counts as not done (not as failed)."""
    _update(key, None)


_saved = {}


def install():
    if not _saved:
        from mlx_lm.models import qwen3_next
        _saved.update(linear=nn.QuantizedLinear.__call__, emb=nn.QuantizedEmbedding.as_linear,
                      sdpa=qwen3_next.scaled_dot_product_attention)
    _install()


def uninstall():
    """Back to MLX's own methods (lookahead stays off in this process)."""
    if _saved and getattr(nn.QuantizedLinear, "_vb_exact", False):
        from mlx_lm.models import qwen3_next
        nn.QuantizedLinear.__call__ = _saved["linear"]
        nn.QuantizedEmbedding.as_linear = _saved["emb"]
        qwen3_next.scaled_dot_product_attention = _saved["sdpa"]
        nn.QuantizedLinear._vb_exact = False


def stream_generate(model, tok, prompt, max_tokens, sampler, prompt_cache, source, stats):
    """mlx_lm.generate.stream_generate (same responses, same text) over generate_step above."""
    from mlx_lm.generate import GenerationResponse, wired_limit
    from mlx_lm.tokenizer_utils import TokenizerWrapper

    if not isinstance(tok, TokenizerWrapper):
        tok = TokenizerWrapper(tok)
    detok = tok.detokenizer
    detok.reset()
    size = len(prompt)
    gen = generate_step(model, prompt, prompt_cache, sampler, max_tokens, source, stats)
    with wired_limit(model, [generation_stream]):
        tic = time.perf_counter()
        prompt_tps, n, token = 0.0, 0, None
        for n, token in enumerate(gen):
            if n == 0:
                prompt_tps = size / (time.perf_counter() - tic)
                tic = time.perf_counter()
            if token in tok.eos_token_ids:
                break
            detok.add_token(token)
            if (n + 1) == max_tokens:
                break
            yield GenerationResponse(text=detok.last_segment, token=token, logprobs=None, from_draft=False,
                                     prompt_tokens=size, prompt_tps=prompt_tps, generation_tokens=n + 1,
                                     generation_tps=(n + 1) / (time.perf_counter() - tic),
                                     peak_memory=mx.get_peak_memory() / 1e9)
        gen.close()
        detok.finalize()
        yield GenerationResponse(text=detok.last_segment, token=token, logprobs=None, from_draft=False,
                                 prompt_tokens=size, prompt_tps=prompt_tps, generation_tokens=n + 1,
                                 generation_tps=(n + 1) / max(1e-9, time.perf_counter() - tic),
                                 peak_memory=mx.get_peak_memory() / 1e9,
                                 finish_reason="stop" if token in tok.eos_token_ids else "length")
