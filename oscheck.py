"""Does this Mac's macOS run the bundled MLX? Checked once at start, before any model download.

An MLX build names the oldest macOS it runs on in its Mach-O header (LC_BUILD_VERSION minos); the
macOS 26 wheel on PyPI is built for 26.2. On an older macOS dyld still loads it (it only refuses
images whose symbols are missing), and the failure comes with the first GPU work: the Metal shaders
and the kernel language need 26.2, so every take would end in "Fehler: RuntimeError" after the
onboarding had downloaded the models. Anything this module cannot read counts as supported: then
VoiceBud starts as it did before the check."""
import ctypes
import importlib.util
import platform
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1
SOFTWARE_UPDATE = "x-apple.systempreferences:com.apple.preferences.softwareupdate"

TEXTS = {
    "de": ("VoiceBud braucht macOS {needed} oder neuer",
           "Auf diesem Mac läuft macOS {running}. Die Spracherkennung rechnet auf dem Grafikchip, "
           "und das geht erst ab macOS {needed}. Das Update ist kostenlos: Systemeinstellungen > "
           "Allgemein > Softwareupdate.",
           "Softwareupdate öffnen", "Beenden"),
    "en": ("VoiceBud needs macOS {needed} or later",
           "This Mac runs macOS {running}. Speech recognition runs on the graphics chip, which "
           "needs macOS {needed}. The update is free: System Settings > General > Software Update.",
           "Open Software Update", "Quit"),
}


def parse_version(text):
    """'26.2' -> (26, 2, 0); None when it does not start with a number."""
    parts = []
    for p in str(text or "").strip().split(".")[:3]:
        if not p.isdigit():
            break
        parts.append(int(p))
    return tuple(parts + [0] * (3 - len(parts))) if parts else None


def version_text(v):
    """(26, 2, 0) -> '26.2', (15, 7, 1) -> '15.7.1'."""
    return ".".join(str(n) for n in (v if v[2] else v[:2]))


def running_macos():
    """macOS version of this Mac. The kernel's value first: SystemVersion.plist, which platform
    reads, is redirected to a compatibility version for some processes (SYSTEM_VERSION_COMPAT)."""
    try:
        buf = ctypes.create_string_buffer(32)
        size = ctypes.c_size_t(len(buf))
        if ctypes.CDLL(None).sysctlbyname(b"kern.osproductversion", buf, ctypes.byref(size), None, 0) == 0:
            v = parse_version(buf.value.decode("ascii", "replace"))
            if v:
                return v
    except (OSError, AttributeError):
        pass
    return parse_version(platform.mac_ver()[0])


def required_macos(path):
    """The minimum macOS a thin 64-bit Mach-O file asks for, or None."""
    try:
        with open(path, "rb") as f:
            magic, _cpu, _sub, _type, ncmds, sizeofcmds, _flags, _res = struct.unpack("<8I", f.read(32))
            if magic != MH_MAGIC_64:
                return None
            cmds = f.read(sizeofcmds)
        off = 0
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<2I", cmds, off)
            if cmd == LC_BUILD_VERSION:
                plat, minos = struct.unpack_from("<2I", cmds, off + 8)
                if plat == PLATFORM_MACOS:
                    return (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
            if size <= 0:
                return None
            off += size
    except (OSError, struct.error):
        pass
    return None


def mlx_library():
    """Path of the bundled libmlx.dylib, found without importing mlx; None without MLX."""
    try:
        spec = importlib.util.find_spec("mlx")
    except (ImportError, ValueError):
        return None
    for loc in (spec.submodule_search_locations or ()) if spec else ():
        lib = Path(loc) / "lib" / "libmlx.dylib"
        if lib.is_file():
            return lib
    return None


def unsupported():
    """(needed, running) as version texts when the bundled MLX needs a newer macOS, else None."""
    try:
        lib = mlx_library()
        needed = required_macos(lib) if lib is not None else None
        running = running_macos()
    except Exception:
        return None
    if needed is None or running is None or running >= needed:
        return None
    return version_text(needed), version_text(running)


def language(setting):
    """Language of the message: the hub setting, 'system' = German on a German Mac, else English."""
    if setting in TEXTS:
        return setting
    try:
        from Foundation import NSLocale
        first = NSLocale.preferredLanguages()[0]
        return "de" if str(first).lower().startswith("de") else "en"
    except Exception:
        return "en"


def explain(needed, running, lang="en"):
    """Tell the user in a system alert why VoiceBud does not start; offers Software Update."""
    title, body, update, quit_ = TEXTS.get(lang, TEXTS["en"])
    print(f"macOS {running} is older than the {needed} the bundled MLX needs: not starting")
    try:
        from AppKit import NSAlert, NSAlertFirstButtonReturn, NSApplication, NSWorkspace
        from Foundation import NSURL
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title.format(needed=needed))
        alert.setInformativeText_(body.format(needed=needed, running=running))
        alert.addButtonWithTitle_(update)
        alert.addButtonWithTitle_(quit_)
        if alert.runModal() == NSAlertFirstButtonReturn:
            NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(SOFTWARE_UPDATE))
    except Exception as e:
        print(f"macOS alert failed: {e!r}")
