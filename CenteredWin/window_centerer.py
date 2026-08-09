import logging
import time
import ctypes
import ctypes.wintypes
import win32api
import win32gui
import win32process

logger = logging.getLogger(__name__)

SWP_NOSIZE     = 0x0001
SWP_NOZORDER   = 0x0004
SWP_NOACTIVATE = 0x0010
NEAR_FULL_RATIO = 0.90


def _ease_out_cubic(t: float) -> float:
    return 1.0 - (1.0 - t) ** 3


def _get_screen_for_hwnd(hwnd, settings):
    """Return (left, top, width, height) of the appropriate monitor work area."""
    if not settings.center_on_window_display and settings.fixed_display_name:
        for hmon, _, _ in win32api.EnumDisplayMonitors(None, None):
            info = win32api.GetMonitorInfo(hmon)
            if info["Device"] == settings.fixed_display_name:
                wa = info["Work"]
                return wa[0], wa[1], wa[2] - wa[0], wa[3] - wa[1]

    # Follow the window's current monitor (MONITOR_DEFAULTTONEAREST = 2)
    hmon = ctypes.windll.user32.MonitorFromWindow(hwnd, 2)
    info = win32api.GetMonitorInfo(hmon)
    wa = info["Work"]
    return wa[0], wa[1], wa[2] - wa[0], wa[3] - wa[1]


def center_window(hwnd, settings):
    try:
        if not win32gui.IsWindowVisible(hwnd):
            return
        if win32gui.IsIconic(hwnd):  # minimized
            return
        rect = win32gui.GetWindowRect(hwnd)
        w = rect[2] - rect[0]
        h = rect[3] - rect[1]
        sx, sy, sw, sh = _get_screen_for_hwnd(hwnd, settings)

        # Skip near-full-screen windows
        if w >= sw * NEAR_FULL_RATIO or h >= sh * NEAR_FULL_RATIO:
            return

        new_x = sx + (sw - w) // 2
        new_y = sy + (sh - h) // 2

        if settings.animation_style == "Instant":
            win32gui.SetWindowPos(
                hwnd, None, new_x, new_y, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
            )
        else:
            steps = 6  if settings.animation_style == "Subtle" else 12
            delay = 0.010 if settings.animation_style == "Subtle" else 0.014
            sx0, sy0 = rect[0], rect[1]
            for i in range(1, steps + 1):
                f = _ease_out_cubic(i / steps)
                x = int(sx0 + (new_x - sx0) * f)
                y = int(sy0 + (new_y - sy0) * f)
                win32gui.SetWindowPos(
                    hwnd, None, x, y, 0, 0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
                )
                time.sleep(delay)
    except Exception as exc:
        logger.exception("Failed to center window hwnd=%s", hwnd)


def center_active_window(settings):
    hwnd = win32gui.GetForegroundWindow()
    if hwnd:
        center_window(hwnd, settings)


def center_all_windows_of_foreground_app(settings):
    fg = win32gui.GetForegroundWindow()
    if not fg:
        return
    _, pid = win32process.GetWindowThreadProcessId(fg)

    def callback(hwnd, hwnds):
        if win32gui.IsWindowVisible(hwnd):
            _, wpid = win32process.GetWindowThreadProcessId(hwnd)
            if wpid == pid:
                hwnds.append(hwnd)
        return True

    hwnds = []
    win32gui.EnumWindows(callback, hwnds)
    for h in hwnds:
        center_window(h, settings)
