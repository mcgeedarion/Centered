# CenteredWin

**This directory previously contained a Python port of Centered for Windows. The Python files have been removed.**

The Windows implementation is no longer maintained in this repository. The original macOS version remains fully supported.

For Windows alternatives, consider:
- Using the macOS version via virtualization
- Native Windows window management tools like PowerToys FancyZones

---

## Original Project Information

This was a lightweight Python port of [Centered](https://github.com/mcgeedarion/Centered) — the macOS window auto-centering utility — reimplemented for Windows using native Win32 APIs.

### Features (Historical Reference)

- **Auto-center** — every new or focused window slides to the center of the screen
- **Ease-out animation** — cubic ease-out curve (Instant / Subtle / Smooth)
- **Center Active Window** — manual hotkey (default `Ctrl+Alt+C`)
- **Center All Windows** — centers all visible windows of the foreground app (default `Ctrl+Shift+C`)
- **Customizable hotkeys** — remap both shortcuts from the Preferences window
- **Per-process exclusion list** — exclude any app by process name
- **Pause Auto-Centering** — temporarily stop automatic moves
- **Multi-screen-support** — center on the window's current display, or pick a fixed display
- **Animation controls** — choose Instant, Subtle, or Smooth motion from the tray menu
- **Diagnostics** — copy a settings/hotkey summary to the clipboard
- **Launch at Login** — register/unregister via the Windows Registry
- **JSON settings** — stored in `%APPDATA%\CenteredWin\settings.json`

### Architecture (Historical Reference)

| File | Responsibility |
|---|---|
| `main.py` | App entry point, tray icon, menu, lifecycle |
| `window_centerer.py` | Win32 centering logic, animation, display selection |
| `window_observer.py` | `SetWinEventHook` for focus/create/restore events |
| `hotkey_manager.py` | `RegisterHotKey` global hotkey registration and dispatch |
| `preferences_ui.py` | Tkinter preferences window |
| `settings.py` | JSON settings load/save, registry login-item management |

### Windows API Mapping (Historical Reference)

| macOS (Original) | Windows (This Port) |
|---|---|
| `AXUIElement` | `SetWindowPos`, `GetWindowRect` via `pywin32` |
| `AXObserver` | `SetWinEventHook` |
| `Carbon` global hotkeys | `RegisterHotKey` |
| `NSStatusItem` (menu bar) | `pystray` (system tray) |
| `UserDefaults` | JSON file in `%APPDATA%` |
| `SMAppService` (login item) | Registry `HKCU\...\Run` |
| `AppleScript` fallback | `psutil` process name lookup |
