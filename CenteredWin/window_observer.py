import ctypes
import ctypes.wintypes
import threading
import win32process
import win32gui

try:
    import psutil
    _PSUTIL = True
except ImportError:
    _PSUTIL = False

WinEventProc = ctypes.WINFUNCTYPE(
    None,
    ctypes.wintypes.HANDLE,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.HWND,
    ctypes.wintypes.LONG,
    ctypes.wintypes.LONG,
    ctypes.wintypes.DWORD,
    ctypes.wintypes.DWORD,
)

EVENT_SYSTEM_FOREGROUND  = 0x0003
EVENT_OBJECT_CREATE      = 0x8000
EVENT_SYSTEM_MINIMIZEEND = 0x0017
WINEVENT_OUTOFCONTEXT    = 0x0000


class WindowObserver:
    def __init__(self, settings, on_window_event):
        self._settings = settings
        self._callback = on_window_event
        self._hooks = []
        self._proc = WinEventProc(self._on_event)  # must keep reference alive
        self._thread = threading.Thread(target=self._start, daemon=True)
        self._thread.start()

    def _on_event(self, hook, event, hwnd, id_obj, id_child, thread, time_ms):
        if not hwnd or not self._settings.auto_center_enabled:
            return
        if _PSUTIL:
            try:
                _, pid = win32process.GetWindowThreadProcessId(hwnd)
                name = psutil.Process(pid).name().replace(".exe", "").lower()
                excluded = [e.lower() for e in self._settings.excluded_process_names]
                if name in excluded:
                    return
            except Exception:
                return
        self._callback(hwnd)

    def _start(self):
        user32 = ctypes.windll.user32
        for evt in (
            EVENT_SYSTEM_FOREGROUND,
            EVENT_OBJECT_CREATE,
            EVENT_SYSTEM_MINIMIZEEND,
        ):
            h = user32.SetWinEventHook(
                evt, evt, None, self._proc, 0, 0, WINEVENT_OUTOFCONTEXT
            )
            self._hooks.append(h)
        msg = ctypes.wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    def stop(self):
        for h in self._hooks:
            ctypes.windll.user32.UnhookWinEvent(h)
        self._hooks.clear()
