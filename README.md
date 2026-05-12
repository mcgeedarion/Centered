# Centered

A lightweight macOS menu-bar utility that automatically centers windows on screen whenever they are created, focused, or deminiaturized.

## Features

- **Auto-center** — every new or focused window slides to the center of your chosen screen
- **Ease-out animation** — cubic ease-out curve for smooth, native-feeling motion
- **Center Active Window** — manual hotkey (default `⌘⌥C`)
- **Center All Windows** — centers every non-minimized window of the frontmost app (default `⌘⇧C`)
- **Customizable hotkeys** — remap both shortcuts from the Preferences window
- **Per-app exclusion list** — exclude any app by bundle ID so it is never auto-centered
- **Multi-screen support** — pick which display to center on; preference persists across launches
- **Launch at Login** — register/unregister as a login item from the menu (macOS 13+)

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13 Ventura or later |
| Xcode | 15 or later |
| Swift | 5.9 or later |

## Permissions

Centered requires two permissions granted in **System Settings → Privacy & Security**:

- **Accessibility** — reads and sets window positions via the AX API
- **Input Monitoring** — listens for the global hotkey while other apps are focused

Both are requested automatically on first launch.

## Entitlements

The app runs **without the App Sandbox** because the Accessibility API requires direct process-level access that the sandbox does not permit for this use case. This is intentional for a personal-use build.

| Entitlement | Reason |
|---|---|
| `accessibility.all` (temporary exception) | Read/write window positions via AXUIElement |
| `automation.apple-events` | AppleScript fallback for apps that don't expose AX window attributes |
| `device.input-monitoring` | Global hotkey capture via NSEvent |
| `files.user-selected.read-only` | Open panel when adding apps to the exclusion list |

## Build & Run

```bash
git clone https://github.com/mcgeedarion/Centered.git
open Centered/Centered.xcodeproj
# Build & Run (⌘R) in Xcode
```

No third-party dependencies. No Swift Package Manager setup required.

## Usage

1. Launch Centered — a rectangle icon appears in the menu bar.
2. Grant Accessibility and Input Monitoring permissions when prompted.
3. Windows will auto-center as you open or focus them.
4. Use **Preferences…** (`⌘,`) from the menu to:
   - Remap hotkeys
   - Add apps to the exclusion list
5. Toggle **Launch at Login** from the menu to start Centered automatically.

## Hotkey Defaults

| Action | Default |
|---|---|
| Center Active Window | `⌘⌥C` |
| Center All Windows | `⌘⇧C` |
| Open Preferences | `⌘,` |

## Architecture

| File | Responsibility |
|---|---|
| `AppDelegate.swift` | App lifecycle, status-bar menu (incrementally rebuilt per section — screens/actions/system), hotkey wiring, AX permission polling |
| `WindowCenterer.swift` | AX centering logic, cubic ease-out animation, AppleScript fallback (dispatched off the main thread to avoid blocking AX callbacks) |
| `WindowObserver.swift` | AXObserver setup, per-app exclusion filtering, explicit retain-counter lifecycle (`selfRetainCount`) |
| `HotKey.swift` | NSEvent-based global/local key monitor, runtime rebind support |
| `PreferencesWindowController.swift` | Preferences UI — hotkey recorder and exclusion list table view |
| `ViewController.swift` | Menu-bar popover/window toggle switch and status indicator |
| `UserDefaults+Centered.swift` | Typed UserDefaults accessors; all preference key strings centralized here |
