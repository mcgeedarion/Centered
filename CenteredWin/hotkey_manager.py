import ctypes
import ctypes.wintypes
import threading
from typing import Dict, Callable, Tuple

MOD_ALT     = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT   = 0x0004
MOD_WIN     = 0x0008
WM_HOTKEY   = 0x0312

VK_MAP = {
    "A": 0x41, "B": 0x42, "C": 0x43, "D": 0x44, "E": 0x45,
    "F": 0x46, "G": 0x47, "H": 0x48, "I": 0x49, "J": 0x4A,
    "K": 0x4B, "L": 0x4C, "M": 0x4D, "N": 0x4E, "O": 0x4F,
    "P": 0x50, "Q": 0x51, "R": 0x52, "S": 0x53, "T": 0x54,
    "U": 0x55, "V": 0x56, "W": 0x57, "X": 0x58, "Y": 0x59,
    "Z": 0x5A,
}


def _parse_hotkey(s: str) -> Tuple[int, int]:
    mods, vk = 0, 0
    for part in s.split("+"):
        p = part.strip().upper()
        if p in ("CTRL", "CONTROL"):
            mods |= MOD_CONTROL
        elif p == "ALT":
            mods |= MOD_ALT
        elif p == "SHIFT":
            mods |= MOD_SHIFT
        elif p == "WIN":
            mods |= MOD_WIN
        else:
            vk = VK_MAP.get(p, 0)
    return mods, vk


class HotKeyManager:
    def __init__(self):
        self._handlers: Dict[int, Callable] = {}
        self._next_id = 1
        self._thread = threading.Thread(target=self._message_loop, daemon=True)
        self._thread.start()

    def register(self, hotkey_str: str, handler: Callable) -> int:
        mods, vk = _parse_hotkey(hotkey_str)
        if not vk:
            return -1
        hid = self._next_id
        self._next_id += 1
        if ctypes.windll.user32.RegisterHotKey(None, hid, mods, vk):
            self._handlers[hid] = handler
            return hid
        return -1

    def unregister(self, hid: int):
        ctypes.windll.user32.UnregisterHotKey(None, hid)
        self._handlers.pop(hid, None)

    def unregister_all(self):
        for hid in list(self._handlers):
            ctypes.windll.user32.UnregisterHotKey(None, hid)
        self._handlers.clear()

    def _message_loop(self):
        msg = ctypes.wintypes.MSG()
        while ctypes.windll.user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY:
                handler = self._handlers.get(msg.wParam)
                if handler:
                    handler()
            ctypes.windll.user32.TranslateMessage(ctypes.byref(msg))
            ctypes.windll.user32.DispatchMessageW(ctypes.byref(msg))
