import ctypes
import ctypes.wintypes
import threading
import time
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
WM_QUIT                   = 0x0012

# Cache for process names: {pid: (name, timestamp)}
_process_name_cache = {}
_process_name_cache_lock = threading.Lock()
_PROCESS_NAME_CACHE_TTL = 60.0  # seconds


def _get_process_name_cached(pid: int) -> str:
    """Get process name with caching to improve performance.
    
    Args:
        pid: Process ID
        
    Returns:
        Process name (without .exe extension) or empty string if not found
    """
    current_time = time.time()
    
    with _process_name_cache_lock:
        if pid in _process_name_cache:
            name, timestamp = _process_name_cache[pid]
            if current_time - timestamp < _PROCESS_NAME_CACHE_TTL:
                return name
    
    # Cache miss or expired - fetch from psutil
    try:
        name = psutil.Process(pid).name().replace(".exe", "").lower()
        with _process_name_cache_lock:
            _process_name_cache[pid] = (name, current_time)
        return name
    except Exception:
        return ""


def _cleanup_process_cache():
    """Remove expired entries from the process name cache."""
    current_time = time.time()
    with _process_name_cache_lock:
        expired = [
            pid for pid, (_, ts) in _process_name_cache.items()
            if current_time - ts >= _PROCESS_NAME_CACHE_TTL
        ]
        for pid in expired:
            del _process_name_cache[pid]


class WindowObserver:
    def __init__(self, settings, on_window_event):
        self._settings = settings
        self._callback = on_window_event
        self._hooks = []
        self._proc = WinEventProc(self._on_event)  # must keep reference alive
        self._thread_id = None
        self._thread = threading.Thread(target=self._start, daemon=True)
        self._thread.start()

    def _on_event(self, hook, event, hwnd, id_obj, id_child, thread, time_ms):
        if not hwnd or not self._settings.auto_center_enabled:
            return
        if _PSUTIL:
            try:
                _, pid = win32process.GetWindowThreadProcessId(hwnd)
                name = _get_process_name_cached(pid)
                if not name:
                    return
                excluded = [e.lower() for e in self._settings.excluded_process_names]
                if name in excluded:
                    return
            except Exception:
                return
        self._callback(hwnd)

    def _start(self):
        user32 = ctypes.windll.user32
        self._thread_id = ctypes.windll.kernel32.GetCurrentThreadId()
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

        if self._thread_id is not None:
            ctypes.windll.user32.PostThreadMessageW(self._thread_id, WM_QUIT, 0, 0)
            self._thread.join(timeout=1.0)
