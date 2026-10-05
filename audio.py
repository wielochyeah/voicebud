"""Mic capture, on demand only: the input stream is opened when recording
starts and fully closed when it stops — so macOS shows the mic-in-use
indicator only while you are actually dictating.

While recording, every 20 ms block goes to `on_chunk` (the take's buffer), and `bands()`
gives 7 calm, log-spaced band levels for the UI. With an `on_chunk` receiver the recorder keeps
no copy of its own (the take's buffer is the one copy of the audio); without one, stop()
returns the recording."""
import threading

import numpy as np
import sounddevice as sd

BAND_EDGES_HZ = np.geomspace(120, 5000, 8)  # 7 log-spaced bands
FFT_N = 1024                                 # 64 ms at 16 kHz
FLOOR_DB, CEIL_DB = -70.0, -28.0             # band level range (after tilt), from real takes
TILT_DB = 5.5                                # speech falls ~6 dB per band; lift the high ones
RMS_FLOOR_DB, RMS_CEIL_DB = -60.0, -15.0
GAMMA = 1.4                                  # > 1 keeps quiet noise low and peaks soft


class Recorder:
    def __init__(self, sample_rate=16000, channels=1, blocksize=320, on_chunk=None):
        self.sample_rate = sample_rate
        self.channels = channels
        self.blocksize = blocksize
        self.on_chunk = on_chunk
        self._chunks = []
        self._recording = False
        self.level = 0.0
        self.peak = 0.0          # loudest block of the take (RMS): tells a dead input from silence
        self._lock = threading.Lock()
        self._stream = None
        self._failed = False      # the last start failed: re-read the devices next time
        self._ring = np.zeros(FFT_N, dtype=np.float32)
        self._window = np.hanning(FFT_N).astype(np.float32)
        freqs = np.fft.rfftfreq(FFT_N, 1 / sample_rate)
        self._band_bins = []
        for lo, hi in zip(BAND_EDGES_HZ[:-1], BAND_EDGES_HZ[1:]):
            a = int(np.searchsorted(freqs, lo))
            self._band_bins.append((a, max(a + 1, int(np.searchsorted(freqs, hi)))))

    def _callback(self, indata, frames, time_info, status):
        block = indata.copy()
        mono = block[:, 0] if block.ndim > 1 else block
        with self._lock:
            if not self._recording:
                return
            if self.on_chunk is None:
                self._chunks.append(block)
            level = float(np.sqrt((mono ** 2).mean()))  # RMS for the waveform UI
            self.level = level if np.isfinite(level) else 0.0
            self.peak = max(self.peak, self.level)
            n = min(mono.size, FFT_N)
            self._ring = np.roll(self._ring, -n)
            self._ring[-n:] = mono[-n:]
        if self.on_chunk is not None:
            self.on_chunk(mono)

    def feed(self, block):
        """Push audio as if it came from the microphone (same path as the device callback)."""
        block = np.asarray(block, dtype=np.float32)
        self._callback(block.reshape(-1, 1) if block.ndim == 1 else block, len(block), None, None)

    def bands(self):
        """(7 band levels 0..1, rms level 0..1) from the last 64 ms: dB-scaled, gamma 1.4."""
        with self._lock:
            x = self._ring * self._window
            rms = self.level
        mag = np.abs(np.fft.rfft(x)) / (FFT_N / 4)
        levels = []
        for i, (a, b) in enumerate(self._band_bins):
            db = 20 * np.log10(np.sqrt(np.mean(mag[a:b] ** 2)) + 1e-9) + TILT_DB * i
            levels.append(_scale(db, FLOOR_DB, CEIL_DB))
        return levels, _scale(20 * np.log10(rms + 1e-9), RMS_FLOOR_DB, RMS_CEIL_DB)

    def start(self, open_stream=True):
        """Open the mic and begin recording (~100ms to spin the stream up).
        open_stream=False records whatever is pushed into feed() (tests, no microphone)."""
        with self._lock:
            self._chunks = []
            self._ring[:] = 0
            self.level = self.peak = 0.0
            self._recording = True
        if open_stream and self._stream is None:
            # PortAudio reads the device list once, at import: a microphone plugged in or AirPods
            # connected later stayed invisible (or the old one silent) until a restart. Re-reading
            # costs well under a millisecond while no stream is open.
            refresh_devices(force=self._failed)
            stream = sd.InputStream(
                samplerate=self.sample_rate, channels=self.channels, dtype="float32",
                blocksize=self.blocksize, callback=self._callback,
            )
            try:
                stream.start()
                self._failed = False
            except Exception:
                # a half-open stream must not be reused: the next take would record nothing
                self._failed = True
                with self._lock:
                    self._recording = False
                try:
                    stream.close()
                except Exception:
                    pass
                raise
            self._stream = stream

    def stop(self):
        """Stop recording, close the mic, and return mono float32 audio (empty when every
        block went to `on_chunk`)."""
        with self._lock:
            self._recording = False
            chunks, self._chunks = self._chunks, []
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        audio = np.concatenate(chunks)
        return (audio[:, 0] if audio.ndim > 1 else audio).flatten()

    @property
    def recording(self):
        return self._recording

    def close(self):
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None


PA_LOCK = threading.Lock()        # PortAudio's device list is shared (recorder, onboarding probe)
_known_input = [None]


def _default_input_id():
    """CoreAudio's default input device id (cheap, no PortAudio)."""
    try:
        import ctypes
        ca = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")

        class Addr(ctypes.Structure):
            _fields_ = [("sel", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("elem", ctypes.c_uint32)]
        fourcc = lambda t: int.from_bytes(t.encode(), "big")
        addr = Addr(fourcc("dIn "), fourcc("glob"), 0)       # kAudioHardwarePropertyDefaultInputDevice
        dev, size = ctypes.c_uint32(0), ctypes.c_uint32(4)
        err = ca.AudioObjectGetPropertyData(ctypes.c_uint32(1), ctypes.byref(addr), 0, None,
                                            ctypes.byref(size), ctypes.byref(dev))
        return dev.value if err == 0 else None
    except Exception:
        return None


def refresh_devices(force=False):
    """PortAudio reads the device list once, at import: a microphone plugged in or AirPods
    connected later stayed invisible (or the old one silent) until a restart. Re-read it when
    CoreAudio's default input changed (or a start failed); PortAudio is never left uninitialised."""
    current = _default_input_id()
    with PA_LOCK:
        if not force and current == _known_input[0] and getattr(sd, "_initialized", 1):
            return
        try:
            if getattr(sd, "_initialized", 0):
                sd._terminate()
        except Exception:
            pass
        try:
            if not getattr(sd, "_initialized", 0):
                sd._initialize()
            _known_input[0] = current
        except Exception:
            pass


def _scale(db, floor, ceil):
    return round(float(np.clip((db - floor) / (ceil - floor), 0.0, 1.0)) ** GAMMA, 3)
