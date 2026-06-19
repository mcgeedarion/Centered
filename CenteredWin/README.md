# Centered for Windows (Python Port)

A lightweight Python port of [Centered](https://github.com/mcgeedarion/Centered) — the macOS window auto-centering utility — reimplemented for Windows using native Win32 APIs.

## Features

- **Auto-center** — every new or focused window slides to the center of the screen
- **Ease-out animation** — cubic ease-out curve (Instant / Subtle / Smooth)
- **Center Active Window** — manual hotkey (default `Ctrl+Alt+C`)
- **Center All Windows** — centers all visible windows of the foreground app (default `Ctrl+Shift+C`)
- **Customizable hotkeys** — remap both shortcuts from the Preferences window
- **Per-process exclusion list** — exclude any app by process name
- **Pause Auto-Centering** — temporarily stop automatic moves
- **Multi-screen support** — center on the window's current display, or pick a fixed display
- **Animation controls** — choose Instant, Subtle, or Smooth motion from the tray menu
- **Diagnostics** — copy a settings/hotkey summary to the clipboard
- **Launch at Login** — register/unregister via the Windows Registry
- **JSON settings** — stored in `%APPDATA%\CenteredWin\settings.json`

## Requirements

- Windows 10 or later
- Python 3.10+

## Installation

```bash
git clone https://github.com/mcgeedarion/Centered.git
cd Centered/CenteredWin
pip install -r requirements.txt
```

## Running

```bash
# With a console window (development)
python main.py

# Without a console window (normal use)
pythonw main.py
```

## Building a Standalone .exe

```bash
pip install pyinstaller
pyinstaller --noconsole --onefile main.py
# Output: dist/main.exe
```

## Hotkey Defaults

| Action | Default |
|---|---|
| Center Active Window | `Ctrl+Alt+C` |
| Center All Windows | `Ctrl+Shift+C` |

All hotkeys can be customized from **Preferences** in the tray menu.

## Architecture

| File | Responsibility |
|---|---|
| `main.py` | App entry point, tray icon, menu, lifecycle |
| `window_centerer.py` | Win32 centering logic, animation, display selection |
| `window_observer.py` | `SetWinEventHook` for focus/create/restore events |
| `hotkey_manager.py` | `RegisterHotKey` global hotkey registration and dispatch |
| `preferences_ui.py` | Tkinter preferences window |
| `settings.py` | JSON settings load/save, registry login-item management |

## Windows API Mapping

| macOS (Original) | Windows (This Port) |
|---|---|
| `AXUIElement` | `SetWindowPos`, `GetWindowRect` via `pywin32` |
| `AXObserver` | `SetWinEventHook` |
| `Carbon` global hotkeys | `RegisterHotKey` |
| `NSStatusItem` (menu bar) | `pystray` (system tray) |
| `UserDefaults` | JSON file in `%APPDATA%` |
| `SMAppService` (login item) | Registry `HKCU\...\Run` |
| `AppleScript` fallback | `psutil` process name lookup |
