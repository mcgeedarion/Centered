import json
import os
import threading
import winreg
from dataclasses import dataclass, field
from typing import List

SETTINGS_PATH = os.path.join(
    os.environ["APPDATA"], "CenteredWin", "settings.json"
)


@dataclass
class AppSettings:
    auto_center_enabled: bool = True
    center_active_hotkey: str = "Ctrl+Alt+C"
    center_all_hotkey: str = "Ctrl+Shift+C"
    excluded_process_names: List[str] = field(default_factory=list)
    animation_style: str = "Smooth"  # Instant | Subtle | Smooth
    launch_at_login: bool = False
    center_on_window_display: bool = True
    fixed_display_name: str = ""
    
    def __init__(self, *args, **kwargs):
        self._lock = threading.Lock()
        super().__init__(*args, **kwargs)

    @staticmethod
    def load() -> "AppSettings":
        try:
            with open(SETTINGS_PATH) as f:
                data = json.load(f)
            return AppSettings(**data)
        except Exception:
            return AppSettings()

    def save(self):
        with self._lock:
            os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
            with open(SETTINGS_PATH, "w") as f:
                json.dump(self.__dict__, f, indent=2)

    def set_launch_at_login(self, enable: bool):
        key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
        exe = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "main.py")
        )
        key = None
        try:
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER, key_path, access=winreg.KEY_SET_VALUE
            )
            if enable:
                winreg.SetValueEx(
                    key, "CenteredWin", 0, winreg.REG_SZ, f'pythonw "{exe}"'
                )
            else:
                try:
                    winreg.DeleteValue(key, "CenteredWin")
                except FileNotFoundError:
                    pass
        finally:
            if key is not None:
                key.Close()
        with self._lock:
            self.launch_at_login = enable
        self.save()
