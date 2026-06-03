# Centered

A lightweight, zero-dependency macOS menu-bar utility that automatically centers windows on screen whenever they are created, focused, or deminiaturized.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Hotkey Defaults](#hotkey-defaults)
- [Permissions & Security](#permissions--security)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)

## Features

- **Auto-center** — every new or focused window slides to the center of your chosen screen
- **Ease-out animation** — cubic ease-out curve for smooth, native-feeling motion
- **Center Active Window** — manual hotkey (default `⌘⌥C`)
- **Center All Windows** — centers every non-minimized window of the frontmost app (default `⌘⇧C`)
- **Customizable hotkeys** — remap both shortcuts from the Preferences window
- **Per-app exclusion list** — exclude any app by bundle ID so it is never auto-centered
- **Multi-screen support** — pick which display to center on; preference persists across launches
- **Launch at Login** — register/unregister as a login item from the menu (macOS 13+)
- **No dependencies** — entirely self-contained with zero external package requirements

## Installation

### Download Latest Release

Download the latest prebuilt binary from [GitHub Releases](https://github.com/mcgeedarion/Centered/releases).

1. Extract `Centered.app` from the `.zip` file
2. Move it to your `/Applications` folder
3. Launch it — the app will request necessary permissions on first run

### Build from Source

```bash
git clone https://github.com/mcgeedarion/Centered.git
cd Centered
open Centered/Centered.xcodeproj
```

Then build and run with `⌘R` in Xcode (or `⌘B` to build only).

**Requirements:**
- Xcode 15 or later
- Swift 5.9 or later
- macOS 13 Ventura or later (to build and run)

## Requirements

| System | Minimum Version |
|---|---|
| **macOS** | 13 Ventura or later |
| **Xcode** (to build) | 15 or later |
| **Swift** (to build) | 5.9 or later |

## Getting Started

1. **Launch Centered** — a small rectangle icon appears in the menu bar
2. **Grant permissions** — grant Accessibility and Input Monitoring when prompted by System Settings
3. **Windows auto-center** — new and focused windows will automatically slide to center
4. **Customize** — use **Preferences…** (`⌘,`) to remap hotkeys or add app exclusions
5. **Persistent settings** — all preferences are remembered between launches

## Usage

### Auto-Centering Behavior

Windows are automatically centered when:
- A new window is created
- You focus an existing window (click its title bar or via Alt+Tab)
- A minimized window is restored

### Manual Actions

| Action | Hotkey | Effect |
|---|---|---|
| Center Active Window | `⌘⌥C` | Centers only the currently focused window |
| Center All Windows | `⌘⇧C` | Centers all non-minimized windows of the frontmost app |
| Open Preferences | `⌘,` | Opens the preferences window |

### Preferences

Access preferences via **Preferences…** (`⌘,`) in the menu bar to:

- **Remap Hotkeys** — change the default keyboard shortcuts to your preference
- **Manage Exclusions** — add apps (by bundle ID) that should never auto-center
- **Select Display** — choose which screen windows center on (if using multiple displays)
- **Launch at Login** — toggle automatic startup with your Mac

## Hotkey Defaults

| Action | Default |
|---|---|
| Center Active Window | `⌘⌥C` |
| Center All Windows | `⌘⇧C` |
| Open Preferences | `⌘,` |

All hotkeys can be customized from the Preferences window.

## Permissions & Security

### Required Permissions

Centered requests two permissions from **System Settings → Privacy & Security**:

| Permission | Purpose | Why Needed |
|---|---|---|
| **Accessibility** | Read and reposition window positions | Core function requires access to window attributes via the Accessibility (AX) API |
| **Input Monitoring** | Listen for global hotkeys | Allows hotkey detection even when Centered is not in focus |

Both permissions are requested automatically on first launch.

### Entitlements & Sandbox Status

The app runs **without the App Sandbox** because the Accessibility API requires direct process-level access that sandboxing does not permit. This is an intentional design choice for a personal-use utility.

**Entitlements:**

| Entitlement | Purpose |
|---|---|
| `accessibility.all` (temporary exception) | Read/write window positions via AXUIElement |
| `automation.apple-events` | AppleScript fallback for apps that don't expose AX window attributes |
| `device.input-monitoring` | Global hotkey capture via NSEvent |
| `files.user-selected.read-only` | Open panel for adding apps to the exclusion list |

## Architecture

Centered is architected as a collection of focused, single-responsibility modules:

| File | Responsibility |
|---|---|
| `AppDelegate.swift` | App lifecycle, status-bar menu (incrementally rebuilt per section — screens/actions/system), hotkey wiring, AX permission polling |
| `WindowCenterer.swift` | AX centering logic, cubic ease-out animation, AppleScript fallback (dispatched off the main thread to avoid blocking AX callbacks) |
| `WindowObserver.swift` | AXObserver setup, per-app exclusion filtering, explicit retain-counter lifecycle (`selfRetainCount`) |
| `HotKey.swift` | NSEvent-based global/local key monitor, runtime rebind support |
| `PreferencesWindowController.swift` | Preferences UI — hotkey recorder and exclusion list table view |
| `ViewController.swift` | Menu-bar popover/window toggle switch and status indicator |
| `UserDefaults+Centered.swift` | Typed UserDefaults accessors; all preference key strings centralized here |

## Troubleshooting

### Permissions not granted on launch

If you miss the permission prompts or they don't appear:

1. Open **System Settings → Privacy & Security**
2. Scroll down to **Accessibility** and ensure `Centered` is in the list and enabled
3. Do the same for **Input Monitoring**
4. Restart Centered

### Hotkeys not working

- **Verify permissions** — Input Monitoring must be granted (see above)
- **Check conflicts** — ensure the hotkey isn't already bound by another app
- **Remap hotkeys** — try assigning different key combinations via Preferences

### Specific apps not centering

Some applications don't expose window positioning via the Accessibility API:

- Add them to the exclusion list in Preferences
- Or use **Center Active Window** (`⌘⌥C`) to manually center them

Centered provides an AppleScript fallback for incompatible apps, but this is less reliable than direct AX access.

### App crashes or windows freeze

If Centered causes windows to freeze or the app crashes:

1. Force quit Centered: `⌘⌥Esc` → select Centered → **Force Quit**
2. Restart the app
3. [File a bug report](https://github.com/mcgeedarion/Centered/issues) with details about which app(s) triggered the issue

## Development

### Building

```bash
git clone https://github.com/mcgeedarion/Centered.git
cd Centered
open Centered/Centered.xcodeproj
```

Build with `⌘B` or run with `⌘R` in Xcode.

### Code Style

- Swift 5.9+ conventions
- Xcode's default formatting rules
- Clear, descriptive variable and function names

### Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly (especially with multiple apps and displays)
4. Submit a pull request with a clear description

### Reporting Bugs

[Open an issue](https://github.com/mcgeedarion/Centered/issues) with:

- macOS version
- Which app(s) were affected
- Steps to reproduce
- Expected vs. actual behavior
- Centered version (from **About Centered** in the menu)

## License

Centered is released under the [MIT License](LICENSE). See the [LICENSE](LICENSE) file for details.

---

**Questions or feedback?** [Open an issue](https://github.com/mcgeedarion/Centered/issues) or reach out on [GitHub Discussions](https://github.com/mcgeedarion/Centered/discussions).