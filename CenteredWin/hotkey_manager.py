import ctypes
import ctypes.wintypes
import logging
import threading
from collections import deque
from typing import Callable, Dict, Tuple

logger = logging.getLogger(__name__)

MOD_ALT     = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT   = 0x0004
MOD_WIN     = 0x0008
WM_HOTKEY   = 0x0312
WM_APP      = 0x8000
WM_HOTKEY_MANAGER_COMMAND = WM_APP + 1
PM_NOREMOVE = 0x0000

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


class _MessageThreadCommand:
    def __init__(self, callback: Callable):
        self.callback = callback
        self.done = threading.Event()
        self.result = None
        self.error = None

    def run(self):
        try:
            self.result = self.callback()
        except Exception as exc:
            self.error = exc
        finally:
            self.done.set()


class HotKeyManager:
    def __init__(self):
        self._handlers: Dict[int, Callable] = {}
        self._next_id = 1
        self._id_lock = threading.Lock()
        self._commands = deque()
        self._commands_lock = threading.Lock()
        self._ready = threading.Event()
        self._thread_ident = None
        self._thread_id = None
        self._thread = threading.Thread(target=self._message_loop, daemon=True)
        self._thread.start()

    def register(self, hotkey_str: str, handler: Callable) -> int:
        mods, vk = _parse_hotkey(hotkey_str)
        if not vk:
            logger.error("Invalid hotkey string: %r", hotkey_str)
            return -1
        with self._id_lock:
            hid = self._next_id
            self._next_id += 1

        def register_on_message_thread():
            if ctypes.windll.user32.RegisterHotKey(None, hid, mods, vk):
                self._handlers[hid] = handler
                return hid
            logger.error(
                "RegisterHotKey failed for %r (mods=%s, vk=%s)",
                hotkey_str, mods, vk
            )
            return -1

        return self._call_on_message_thread(register_on_message_thread, -1)

    def unregister(self, hid: int):
        def unregister_on_message_thread():
            ctypes.windll.user32.UnregisterHotKey(None, hid)
            self._handlers.pop(hid, None)

        self._call_on_message_thread(unregister_on_message_thread)

    def unregister_all(self):
        def unregister_all_on_message_thread():
            for hid in list(self._handlers):
                ctypes.windll.user32.UnregisterHotKey(None, hid)
            self._handlers.clear()

        self._call_on_message_thread(unregister_all_on_message_thread)

    def _call_on_message_thread(self, callback: Callable, default=None):
        if threading.get_ident() == self._thread_ident:
            return callback()
        if not self._ready.wait(timeout=5.0):
            logger.error("HotKeyManager message thread did not become ready")
            return default

        command = _MessageThreadCommand(callback)
        with self._commands_lock:
            self._commands.append(command)

        if not ctypes.windll.user32.PostThreadMessageW(
            self._thread_id, WM_HOTKEY_MANAGER_COMMAND, 0, 0
        ):
            with self._commands_lock:
                try:
                    self._commands.remove(command)
                except ValueError:
                    pass
            return default

        if not command.done.wait(timeout=5.0):
            logger.error("HotKeyManager command timed out")
            return default
        if command.error:
            logger.error("HotKeyManager command failed: %s", command.error)
            return default
        return command.result

    def _drain_commands(self):
        while True:
            with self._commands_lock:
                if not self._commands:
                    return
                command = self._commands.popleft()
            command.run()

    def _message_loop(self):
        user32 = ctypes.windll.user32
        self._thread_ident = threading.get_ident()
        self._thread_id = ctypes.windll.kernel32.GetCurrentThreadId()

        msg = ctypes.wintypes.MSG()
        # Force this thread's message queue to exist before other threads post
        # control messages to it.
        user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, PM_NOREMOVE)
        self._ready.set()

        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY_MANAGER_COMMAND:
                self._drain_commands()
            elif msg.message == WM_HOTKEY:
                handler = self._handlers.get(msg.wParam)
                if handler:
                    handler()
            ctypes.windll.user32.TranslateMessage(ctypes.byref(msg))
            ctypes.windll.user32.DispatchMessageW(ctypes.byref(msg))
