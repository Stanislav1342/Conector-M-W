"""Python host for the native Conector-M-W Windows receiver."""

import ctypes
import json
import sys
from pathlib import Path
from threading import RLock

__all__ = ["Receiver"]
_lock = RLock()
_library = None
_active_receiver = None


def _native():
    global _library
    if sys.platform != "win32":
        raise OSError("Conector-M-W Receiver runs on Windows.")
    if _library is None:
        library = ctypes.CDLL(str(Path(__file__).with_name("prilo_receiver.dll")))
        for name in ("ConectorStart", "ConectorNewPairingCode", "ConectorConnectionDetails"):
            function = getattr(library, name)
            function.argtypes = []
            function.restype = ctypes.c_void_p
        library.ConectorStop.argtypes = []
        library.ConectorStop.restype = None
        library.ConectorFree.argtypes = [ctypes.c_void_p]
        library.ConectorFree.restype = None
        _library = library
    return _library


def _read(library, name, field="code"):
    pointer = getattr(library, name)()
    if not pointer:
        raise RuntimeError("Conector-M-W Receiver returned no result.")
    try:
        result = json.loads(ctypes.string_at(pointer))
    finally:
        library.ConectorFree(pointer)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result[field], result


class Receiver:
    """Run one receiver in the current Windows desktop session."""

    def __init__(self):
        self._running = False
        self.pairing_code = None
        self.version = ""

    def start(self):
        """Start the receiver and return its one-time pairing code."""
        global _active_receiver
        with _lock:
            if _active_receiver is not None:
                raise RuntimeError("A Conector-M-W Receiver is already running in this Python process.")
            library = _native()
            code, raw = _read(library, "ConectorStart")
            self._running = True
            _active_receiver = self
            self.pairing_code = code
            self.version = raw.get("version", "")
            return code

    def new_pairing_code(self):
        with _lock:
            if not self._running:
                raise RuntimeError("Conector-M-W Receiver is not running.")
            self.pairing_code, _ = _read(_native(), "ConectorNewPairingCode")
            return self.pairing_code

    def connection_details(self):
        """Return local setup details, including the private access code."""
        with _lock:
            if not self._running:
                raise RuntimeError("Conector-M-W Receiver is not running.")
            details, _ = _read(_native(), "ConectorConnectionDetails", "details")
            return details

    def close(self):
        global _active_receiver
        with _lock:
            if self._running:
                _native().ConectorStop()
                self._running = False
                _active_receiver = None
                self.pairing_code = None
                self.version = ""

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_exception):
        self.close()
