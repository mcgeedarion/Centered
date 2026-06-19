import threading, sys
import win32clipboard
import pystray
from PIL import Image, ImageDraw
from settings import AppSettings
from window_centerer import center_window, center_active_window, center_all_windows_of_foreground_app
from hotkey_manager import HotKeyManager
from window_observer import WindowObserver


def make_icon():
    """Generate a simple crosshair tray icon; replace with a real .ico for production."""
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([8, 8, 56, 56], outline="white", width=4)
    d.line([32, 8, 32, 56], fill="white", width=2)
    d.line([8, 32, 56, 32], fill="white", width=2)
    return img


class CenteredApp:
    def __init__(self):
        self.settings = AppSettings.load()
        self.hotkeys = HotKeyManager()
        self.observer = None
        self._bind_hotkeys()
        self._start_observer()

    def _bind_hotkeys(self):
        self.hotkeys.unregister_all()
        self.hotkeys.register(
            self.settings.center_active_hotkey,
            lambda: center_active_window(self.settings)
        )
        self.hotkeys.register(
            self.settings.center_all_hotkey,
            lambda: center_all_windows_of_foreground_app(self.settings)
        )

    def _start_observer(self):
        if self.observer:
            self.observer.stop()
        self.observer = WindowObserver(
            self.settings,
            lambda h: center_window(h, self.settings)
        )

    def _on_preferences(self, icon, item):
        from preferences_ui import PreferencesWindow
        def open_prefs():
            PreferencesWindow(self.settings, self._bind_hotkeys)
        threading.Thread(target=open_prefs, daemon=True).start()

    def _toggle_pause(self, icon, item):
        self.settings.auto_center_enabled = not self.settings.auto_center_enabled
        self.settings.save()
        icon.update_menu()

    def _set_animation(self, style):
        def fn(icon, item):
            self.settings.animation_style = style
            self.settings.save()
            icon.update_menu()
        return fn

    def _copy_diagnostics(self, icon, item):
        lines = [
            "Centered for Windows — Diagnostics",
            f"Auto-Center: {self.settings.auto_center_enabled}",
            f"Animation:   {self.settings.animation_style}",
            f"Hotkey (Active): {self.settings.center_active_hotkey}",
            f"Hotkey (All):    {self.settings.center_all_hotkey}",
            f"Excluded: {', '.join(self.settings.excluded_process_names) or 'none'}",
            f"Launch at Login: {self.settings.launch_at_login}",
        ]
        text = "\n".join(lines)
        win32clipboard.OpenClipboard()
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardText(text)
        win32clipboard.CloseClipboard()

    def _quit(self, icon, item):
        self.observer.stop()
        self.hotkeys.unregister_all()
        icon.stop()

    def run(self):
        menu = pystray.Menu(
            pystray.MenuItem(
                "Center Active Window",
                lambda i, it: center_active_window(self.settings)
            ),
            pystray.MenuItem(
                "Center All Windows",
                lambda i, it: center_all_windows_of_foreground_app(self.settings)
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                lambda item: "▶ Resume Auto-Centering"
                    if not self.settings.auto_center_enabled
                    else "⏸ Pause Auto-Centering",
                self._toggle_pause
            ),
            pystray.MenuItem("Animation Style", pystray.Menu(
                *[
                    pystray.MenuItem(
                        style,
                        self._set_animation(style),
                        checked=lambda item, st=style: self.settings.animation_style == st
                    )
                    for style in ("Instant", "Subtle", "Smooth")
                ]
            )),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Preferences…",     self._on_preferences),
            pystray.MenuItem("Copy Diagnostics", self._copy_diagnostics),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit Centered",    self._quit),
        )
        icon = pystray.Icon("Centered", make_icon(), "Centered", menu)
        icon.run()


if __name__ == "__main__":
    CenteredApp().run()
