import json
import os
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

    @staticmethod
    def load() -> "AppSettings":
        try:
            with open(SETTINGS_PATH) as f:
                data = json.load(f)
            return AppSettings(**data)
        except Exception:
            return AppSettings()

    def save(self):
        os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
        with open(SETTINGS_PATH, "w") as f:
            json.dump(self.__dict__, f, indent=2)

    def set_launch_at_login(self, enable: bool):
        key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
        exe = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "main.py")
        )
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, key_path, access=winreg.KEY_SET_VALUE
        ) as key:
            if enable:
                winreg.SetValueEx(
                    key, "CenteredWin", 0, winreg.REG_SZ, f'pythonw "{exe}"'
                )
            else:
                try:
                    winreg.DeleteValue(key, "CenteredWin")
                except FileNotFoundError:
                    pass
        self.launch_at_login = enable
        self.save()
