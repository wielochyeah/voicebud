"""Speech recognition on the kernels of older Macs, on this Mac (10.10.). MLX picks its GPU kernels by
the GPU's architecture, and MLX_METAL_GPU_ARCH overrides what it reads: applegpu_g13g is an M1,
g14g an M2, g15g an M3, g16g an M4 (the M5 Pro's neural-accelerator kernels need gen 17 and are then
left out). That proves the computation path of those chips, not their hardware or speed.

For every architecture, each clip is transcribed with the encoder memo off and on; the texts must be
identical. Prints hashes, languages, temperatures and encoder counts only, never text. Not a unit test,
and it loads Whisper: run it only while nothing else measures on the GPU.

    .venv/bin/python tests/oldchip_parity.py [--arch native,applegpu_g13g,...] [--clips a,b]"""
import hashlib
import json
import os
import subprocess
import sys

ARCHS = ["native", "applegpu_g13g", "applegpu_g14g", "applegpu_g15g", "applegpu_g16g"]
CLIPS = ["tts-de-short", "tts-de-long", "tts-en", "tts-de-noisy", "nils-01"]


def child(arch, clips):
    if arch != "native":
        os.environ["MLX_METAL_GPU_ARCH"] = arch          # before MLX initialises the device
    import _util
    import yaml
    import mlx.core as mx
    import transcribe as tr

    cfg = yaml.safe_load((_util.ROOT / "config.yaml").read_text())["stt"]
    stt = tr.Transcriber(cfg)
    stt.load()
    info = mx.metal.device_info() if hasattr(mx, "metal") else {}
    print(json.dumps({"device": str(info.get("architecture", "?")), "arch": arch}), flush=True)
    plain = tr.EncoderMemo.encode
    for name in clips:
        audio = _util.load_wav(name)
        for memo in (False, True):
            tr.EncoderMemo.encode = plain if memo else (lambda self, x, compute: compute(x))
            mx.random.seed(11)                            # the fallback samples at T=0.4: same draws
            text, lang = stt.transcribe(audio, final=True)
            print(json.dumps({"clip": name, "memo": memo, "sha": hashlib.sha256(text.encode()).hexdigest()[:16],
                              "chars": len(text), "lang": lang, "temp": stt.last_temperature,
                              "enc": list(stt.last_encoder)}), flush=True)
    tr.EncoderMemo.encode = plain


def main():
    archs = sys.argv[sys.argv.index("--arch") + 1].split(",") if "--arch" in sys.argv else ARCHS
    clips = sys.argv[sys.argv.index("--clips") + 1].split(",") if "--clips" in sys.argv else CLIPS
    failed = 0
    for arch in archs:
        out = subprocess.run([sys.executable, __file__, "--child", arch, ",".join(clips)],
                             capture_output=True, text=True, env=dict(os.environ))
        rows = [json.loads(line) for line in out.stdout.splitlines() if line.startswith("{")]
        if out.returncode != 0 or not rows:
            print(f"{arch}: failed (exit {out.returncode})\n{out.stderr[-1500:]}")
            failed += 1
            continue
        print(f"== {arch} (MLX sees {rows[0].get('device')})")
        by = {}
        for r in rows[1:]:
            by.setdefault(r["clip"], {})[r["memo"]] = r
        for clip, pair in by.items():
            off, on = pair.get(False), pair.get(True)
            same = off and on and (off["sha"], off["lang"], off["temp"]) == (on["sha"], on["lang"], on["temp"])
            failed += 0 if same else 1
            print(f"  {clip:14} {'same' if same else 'DIFFERENT'}  sha {on['sha'] if on else '?'}  {on['lang'] if on else '?'}"
                  f"  T{on['temp'] if on else '?'}  enc off {off['enc'] if off else '?'} / on {on['enc'] if on else '?'}")
    print("all identical" if not failed else f"{failed} problem(s)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if "--child" in sys.argv:
        i = sys.argv.index("--child")
        child(sys.argv[i + 1], sys.argv[i + 2].split(","))
    else:
        main()
