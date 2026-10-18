# Centered: File-by-File Audit Ledger

**Audited revision:** `352d08a85149ddb4dfb1f733102141234e06369c` on `main`  
**Audit date:** 2026-10-18  
**Method:** Static source/configuration review plus GitHub Actions build-log inspection. The audit is line-oriented and reproducible, but does not claim runtime validation on a physical macOS desktop.

## Severity scale

- **P0, Blocker:** repository does not compile or core verification cannot proceed.
- **P1, High:** major feature can fail or cause an unintended user-visible action.
- **P2, Medium:** feature edge case, data integrity, portability, or reliability issue.
- **P3, Low:** test gap, performance, maintainability, or documentation issue.

## Confirmed findings

### C-01. Carbon callback violates Swift actor isolation

- **Severity:** P0, build blocker
- **File/range:** `Centered/HotKey.swift:324-328`
- **Evidence:** GitHub Actions `Build and test` failed compiling `HotKey.swift:326:66`: “call to main actor-isolated instance method 'handleCarbonEvent' in a synchronous nonisolated context.”
- **Reproduction:** Run `xcodebuild -project Centered.xcodeproj -scheme Centered -configuration Debug clean test CODE_SIGNING_ALLOWED=NO` on a macOS runner with Xcode 16.4. The current CI workflow reproduces it.
- **Root cause:** `HotKey` is `@MainActor`, but Carbon invokes the global `carbonHotKeyHandler` callback from a nonisolated C callback context. The callback directly calls the actor-isolated instance method.
- **Correction:** Keep Carbon callback work synchronous only long enough to read and validate the `EventHotKeyID`, then hand a value-type event identifier to a main-actor-isolated handler. Do not capture and defer the borrowed `EventRef` beyond the callback. Alternatively, use a carefully justified `MainActor.assumeIsolated` only if the Carbon callback's main-thread execution is explicitly guaranteed and asserted.
- **Regression tests:** Add a unit-testable dispatch layer that proves unknown IDs are ignored and matching IDs invoke exactly one handler. CI must pass both Debug `clean test` and Release archive smoke test. Treat all actor-isolation warnings as errors in a follow-up Swift 6 compatibility job.

### C-02. AppleScript move-to-display math treats right/bottom coordinates as width/height

- **Severity:** P1, incorrect window placement
- **File/range:** `Centered/AppleScriptCenterer.swift:169-198`, especially 186-188
- **Reproduction:** Force the AX path to fail for an app, use the Move to Display shortcut, and target a display whose bounds have a nonzero origin or whose right/bottom edge is not equal to its width/height. Compare the final origin with the center of that display.
- **Root cause:** The generated script stores `item 3 of screenBounds` and `item 4 of screenBounds` directly as width and height. The tuple represents left, top, right, bottom, so width and height must be computed as right minus left and bottom minus top. The centering script already performs those subtractions; the move-to-display script does not.
- **Correction:** Generate `screenLeft`, `screenTop`, `screenWidth = right - left`, and `screenHeight = bottom - top` consistently, then compute the target origin from those values.
- **Regression tests:** Add script-generation tests for an origin-zero display and a display at (1920, 40) with a 1200×800 frame. Assert generated width/height expressions subtract the origin and the computed target is centered. Add a runtime multi-monitor test for a secondary display.

### C-03. Bulk-centering fallback only retries one window

- **Severity:** P2, incomplete operation
- **File/range:** `Centered/WindowCenterer.swift:169-187`
- **Reproduction:** Open multiple non-minimized windows in one application, make one window reject AX positioning while the others accept it, then invoke Center All Windows.
- **Root cause:** The AX loop attempts each window, but if any one fails, the fallback invokes a script that centers only the application's front window. Failed non-front windows remain uncentered.
- **Correction:** Track the specific windows that failed. If AppleScript can reliably target a specific window, pass a stable window identifier to the fallback. Otherwise report partial failure and avoid implying that every window was centered. Do not run a single front-window fallback as if it repairs all failed windows.
- **Regression tests:** Use a fake centering backend to simulate a mixed success/failure set and assert each failed window receives a fallback attempt or is explicitly reported as unhandled.

### C-04. Automatic fallback can activate another application and target its front window rather than the event window

- **Severity:** P1, focus disruption / wrong window
- **File/range:** `Centered/WindowCenterer.swift:228-237`; `Centered/AppleScriptCenterer.swift:29-58, 85-122`
- **Reproduction:** Have an app with an AX-inaccessible window generate an event while the user is working in a different app. Observe focus and window placement when the fallback executes.
- **Root cause:** The fallback is queued with the originating process, which avoids targeting an unrelated frontmost process, but the generated AppleScript still issues `activate` and centers `front window`. This can steal focus and may center a different window in the same app than the AX window that triggered the fallback.
- **Correction:** Prefer a fallback that targets a specific window without activating the app. If AppleScript requires activation or only exposes the front window, restrict this fallback to explicit user-initiated actions, or make the focus-stealing behavior an explicit documented tradeoff. Do not use this fallback for background automatic events when it would change the active app.
- **Regression tests:** Integration test with app A's AX operation forced to fail while app B remains active. Assert app B stays frontmost and the intended window, not merely app A's front window, is moved.

### C-05. AX event resolution can center a different window than the one that changed

- **Severity:** P2, automatic-centering correctness
- **File/range:** `Centered/WindowObserver.swift:254-291`
- **Reproduction:** In an application with two windows, create or restore a non-focused window while another window remains focused. Observe which window moves.
- **Root cause:** The callback is registered on the application AX element. The handler resolves the focused window first for every notification, then chooses the first non-minimized window. It does not use `notificationName` to distinguish create, restore, and focus-change events or identify the created/restored window.
- **Correction:** Make event resolution notification-specific. Track observed window identities and compare the app's window list for create/restore events; use the focused-window attribute for focus-change events. If the intended window cannot be resolved unambiguously, skip instead of moving a potentially unrelated window.
- **Regression tests:** Simulate create, restore, and focus-change notifications with multiple windows and assert the expected window identity is passed to the centering callback.

### C-06. Centering skips windows whose AXMain attribute is false

- **Severity:** P2, missed windows
- **File/range:** `Centered/WindowCenterer.swift:164-168`
- **Reproduction:** Focus a secondary/key window in an app that distinguishes its main window from its key window, then trigger auto-centering.
- **Root cause:** The guard rejects any window where `kAXMainAttribute` is explicitly false. Main-window status and key/focused-window status are different concepts in AppKit, so a focused window can be rejected.
- **Correction:** Base automatic centering on the actual event/focused window and minimized state. Remove the main-window restriction unless there is a documented product requirement for it.
- **Regression tests:** Test a focused, non-main window and verify it is centered; retain tests confirming minimized windows are skipped.

### C-07. Hotkey activation failures are logged but app remains reported as enabled

- **Severity:** P2, misleading application state
- **File/range:** `Centered/AppDelegate.swift:733-769`
- **Reproduction:** Start Centered with one default shortcut already registered by another app, then inspect the status and try the conflicting shortcut.
- **Root cause:** `isEnabled` becomes true before the six shortcuts are registered. Individual failures are logged, but no error is surfaced and the enabled status remains unchanged.
- **Correction:** Track activation status per hotkey, surface actionable errors, and distinguish “auto-centering enabled” from “all shortcuts registered.” Allow a failed shortcut to retry after the conflict clears.
- **Regression tests:** Inject one failed registration among successful registrations. Verify the others remain active, diagnostics identify the failed shortcut, and the UI does not claim all shortcuts are working.

### C-08. Failed observer retry validation can leave a partial observer without exclusion metadata

- **Severity:** P2, exclusion enforcement / observer lifecycle
- **File/range:** `Centered/WindowObserver.swift:202-220`
- **Reproduction:** Cause a partial notification-registration retry, then terminate the process or make its AX element unavailable during retry. Relaunch an app with that bundle ID excluded and inspect whether events are ignored.
- **Root cause:** The failed-PID branch removes `bundleIDs[pid]` and the retry entry, but does not remove an existing observer entry or its run-loop source. The remaining observer can continue delivering callbacks without the bundle ID needed for exclusion filtering.
- **Correction:** On PID validation failure, remove the observer and release its refcon, clear all retry/notification state, and avoid dropping exclusion metadata while an observer is still active.
- **Regression tests:** Exercise partial registration followed by failed PID validation. Assert the observer is removed, the refcon is released once, and no callback can bypass exclusion filtering.

### C-09. Keychain failure can silently invalidate persisted exclusion lists

- **Severity:** P2, settings integrity
- **File/range:** `Centered/UserDefaults+Centered.swift:159-220` and `Centered/UserDefaults+Centered.swift:224-279`
- **Reproduction:** Run while the Keychain is unavailable or locked, or inject a non-success Security framework status during key/tag read or write. Save an exclusion, restart, and inspect the exclusion list.
- **Root cause:** `hmacKey()` logs key-storage failure but still returns the newly generated in-memory key. The caller cannot distinguish durable key storage from failure. `store`/tag saving also logs failures without propagating them. Subsequent verification can fail and the getter returns an empty set, silently losing effective exclusions.
- **Correction:** Return a throwing/result-based key operation. Do not generate a replacement key for transient Keychain errors such as interaction-not-allowed. Keep existing data unchanged and surface a recoverable settings-integrity warning if key/tag writes fail.
- **Regression tests:** Inject Keychain success, item-not-found, interaction-not-allowed, add failure, update failure, and tag-write failure. Verify existing exclusions remain recoverable and failures are visible.

### C-10. Actor-isolation protocol declarations are not isolated consistently

- **Severity:** P2, future compiler compatibility
- **File/range:** `Centered/AppDelegate.swift:47-83`, `Centered/AppDelegate.swift:419-422`, and implementations around 497-604
- **Evidence:** Current CI build logs contain warnings that main-actor-isolated properties and methods satisfy nonisolated requirements of `AppCoordinating` and `PreferencesHost`. The compiler explicitly says these become errors in Swift 6 language mode.
- **Reproduction:** Review the current GitHub Actions build log, or compile with Swift 6 language mode after addressing C-01.
- **Root cause:** The protocols describe AppKit/UI-facing requirements without matching `@MainActor` isolation, while their concrete implementation is main-actor isolated.
- **Correction:** Mark the UI/coordinator protocols `@MainActor` where their contracts are UI-bound. Check every conformer and closure boundary, then migrate deliberately rather than suppressing warnings.
- **Regression tests:** Add a Swift 6 language-mode compile job or strict-concurrency build. It should produce no actor-isolation warnings for these protocols.

### C-11. Menu “section rebuilds” reconstruct the whole menu

- **Severity:** P3, avoidable work
- **File/range:** `Centered/AppDelegate.swift:146-160`
- **Reproduction:** Toggle a setting that only affects one menu section, or change the selected display repeatedly, and profile menu construction.
- **Root cause:** `rebuildScreenSection()` and `rebuildActionsSection()` both call the same full `rebuildMenu()`, which recreates screen, action, and system items.
- **Correction:** Update only the affected section while preserving menu item identity where practical. If the menu is cheap enough, remove the section-only abstraction and use one explicit full rebuild to avoid a misleading API.
- **Regression tests:** Add a unit test around menu-state generation or a performance test proving screen-only updates do not regenerate unrelated sections.

### C-12. Screen selection is keyed by localized display name

- **Severity:** P2, multi-display ambiguity
- **File/range:** `Centered/AppDelegate.swift:175-181, 286-289, 497-503, 714-730`
- **Reproduction:** Use two displays with identical localized names, rename a display, disconnect/reconnect it, and inspect selected-display restoration.
- **Root cause:** The selected display is persisted and passed through menu items by `localizedName`. Names can collide or change and are not stable display identities.
- **Correction:** Persist a stable display identifier when macOS exposes one, with a deterministic fallback for disconnected displays. If a stable identifier is unavailable, detect ambiguous matches and fall back predictably.
- **Regression tests:** Test duplicate names, renamed displays, missing displays, and reconnect behavior.

### C-13. UI tests do not assert user-visible behavior

- **Severity:** P3, regression coverage gap
- **File/range:** `CenteredUITests/CenteredUITests.swift:13-25`; `CenteredUITests/CenteredUITestsLaunchTests.swift:13-22`
- **Reproduction:** Read the UI test bodies or run the test suite. `testExample` only launches the app; `testLaunch` only captures a screenshot.
- **Root cause:** The tests are Xcode template smoke tests and do not assert menu availability, preferences, toggle state, permissions, or centering outcomes.
- **Correction:** Replace the empty example with stable assertions for launch/menu state and preference interactions. Keep Accessibility permission-dependent integration tests separate and clearly marked.
- **Regression tests:** Assert the menu exists, the enabled/disabled state is reflected in UI, preferences open and close, hotkey conflicts show an alert, and display options update after screen changes.

### C-14. Committed Xcode user-state files pollute the repository

- **Severity:** P3, repository hygiene
- **File/range:** `Centered.xcodeproj/project.xcworkspace/xcuserdata/mcgeedarion.xcuserdatad/UserInterfaceState.xcuserstate`; `Centered.xcodeproj/xcuserdata/mcgeedarion.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist`; related `xcuserdata` paths in the repository tree
- **Reproduction:** Clone the repository in another Xcode environment and inspect the workspace's restored UI state and breakpoints.
- **Root cause:** Per-user Xcode state is tracked alongside shared project/scheme files.
- **Correction:** Remove user-specific workspace state and breakpoints from version control, and add/confirm ignore rules for `xcuserdata/` and `*.xcuserstate`. Retain the shared scheme under `xcshareddata`.
- **Regression tests:** Check `git ls-files` for tracked `xcuserdata` and `*.xcuserstate` paths in CI.

### C-15. Project signing team is hard-coded in build settings

- **Severity:** P2, source-build portability
- **File/range:** `Centered.xcodeproj/project.pbxproj:411-462, 471-531`
- **Reproduction:** Build from a machine that does not have the configured development team available with automatic signing enabled.
- **Root cause:** `DEVELOPMENT_TEAM = 54B2A9RJ99` is embedded in app and test build configurations.
- **Correction:** Remove the personal team from shared project settings or parameterize it through an xcconfig/local build setting. Document the signing requirements for release archives.
- **Regression tests:** Build unsigned in CI and validate a local archive using a separately supplied signing identity/team.

### C-16. Release script is not exercised end-to-end by CI

- **Severity:** P3, release process gap
- **File/range:** `scripts/release_archive.sh:1-58`; `.github/workflows/ci.yml:18-31`
- **Reproduction:** Compare CI's direct `xcodebuild` commands with the release script and run the script on a clean macOS host.
- **Root cause:** CI duplicates a portion of the script instead of invoking the script or testing its packaging, zip, codesign, and Gatekeeper branches. The two paths can drift.
- **Correction:** Factor build/archive commands into a shared script with explicit CI options, or have CI execute the release script in a controlled unsigned mode and assert the expected archive and zip outputs.
- **Regression tests:** In CI, assert the archive contains `Centered.app`, the zip exists, and signing/assessment failures are reported according to the selected release mode.

## File-by-file inventory

“Reviewed” means source/configuration was inspected statically. It does not mean every runtime branch was executed.

| File or group | Status | Ledger references / notes |
|---|---|---|
| `.github/workflows/ci.yml` | Reviewed | C-01, C-16. CI's current build fails at the Carbon callback compile error. |
| `.gitignore` | Reviewed | Verify/extend Xcode user-state exclusions as part of C-14. |
| `Centered.xcodeproj/project.pbxproj` | Reviewed | C-15. macOS deployment target is 13.0; Swift language mode is 5.0. |
| `Centered.xcodeproj/xcshareddata/xcschemes/Centered.xcscheme` | Reviewed | Shared scheme exists; UI test target is configured but its tests are weak, see C-13. |
| `Centered.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | Reviewed | No functional defect identified in this static pass. |
| `Centered.xcodeproj/**/xcuserdata/**` | Reviewed | C-14, per-user state is tracked. |
| `Centered/AppDelegate.swift` | Reviewed | C-07, C-10, C-11, C-12. |
| `Centered/AppleScriptCenterer.swift` | Reviewed | C-02, C-04. Also inspect AppleScript permissions and error reporting during runtime validation. |
| `Centered/Centered.entitlements` | Reviewed | App sandbox is explicitly false; entitlements match the documented unsandboxed design. Validate hardened-runtime/notarization behavior during release testing. |
| `Centered/Info.plist` | Reviewed | No static defect identified in declared app metadata and usage descriptions. |
| `Centered/HotKey.swift` | Reviewed | C-01. C-10 relates to actor isolation across the coordinator protocols. |
| `Centered/PreferencesWindowController.swift` | Reviewed | C-13. Also test failed hotkey rebind rollback and preference persistence end-to-end. |
| `Centered/Settings.swift` | Reviewed | No direct defect confirmed; reset delegates to defaults and HMAC tag reset. |
| `Centered/UserDefaults+Centered.swift` | Reviewed | C-09. Keychain failure paths need injectable tests. |
| `Centered/ViewController.swift` | Reviewed | No direct defect confirmed in notification cleanup or toggle/status update paths. |
| `Centered/WindowCenterer.swift` | Reviewed | C-03, C-04, C-06, C-12. Geometry unit tests exist but do not exercise AX/runtime behavior. |
| `Centered/WindowObserver.swift` | Reviewed | C-05, C-08. Observer registration, retry and callback routing need integration tests. |
| `CenteredTests/CenteredTests.swift` | Reviewed | Geometry, animation, bundle-ID, shortcut-decoding, settings, and AppleScript-generation tests exist. No observer/hotkey integration tests; see C-13. |
| `CenteredUITests/CenteredUITests.swift` | Reviewed | C-13, launch only. |
| `CenteredUITests/CenteredUITestsLaunchTests.swift` | Reviewed | C-13, screenshot only. |
| `Centered/Assets.xcassets/**` | Inventory reviewed | App icon and accent-color asset catalogs are present. No asset defect confirmed in this code-focused pass. |
| `Centered/Base.lproj/Main.storyboard` | Inventory reviewed | Large storyboard; visual layout and outlet wiring still require Xcode runtime inspection. |
| `CenteredWin/.gitignore` | Reviewed | Windows implementation is absent; see its README. |
| `CenteredWin/README.md` | Reviewed | Clearly marks the Windows port as removed/historical. No build job should reference removed files. |
| `README.md` | Reviewed | Build path and license link are now consistent. Architecture text still says `selfRetainCount` for WindowObserver, which does not match the current `ObserverBox` implementation. |
| `SECURITY.md` | Reviewed | Reporting and support policy is now present. Verify private vulnerability reporting is enabled or provide a confirmed private contact path. |
| `LICENSE` | Reviewed | MIT license file now exists, matching README. Confirm copyright/permission terms are intended before public distribution. |

## Performance opportunities

These are optimization candidates, not proven performance defects. Profile before changing behavior.

1. **AX attribute reads:** `Centered/WindowCenterer.swift:62-111, 250-260`. A centering operation queries size, position, minimized/main state, validity, and then reads attributes again during animation. Cache per-operation reads where safe and measure AX calls per window.
2. **Animation workload:** `Centered/WindowCenterer.swift:267-329`. Smooth animation performs up to 16 AX position writes per window. Profile multi-window bursts, cancel stale work promptly, and consider coalescing target updates.
3. **Full menu reconstruction:** `Centered/AppDelegate.swift:146-160`. Address C-11.
4. **Serial AppleScript queue:** `Centered/AppleScriptCenterer.swift:12-16, 43-58, 120-122, 158-199`. A serial queue avoids concurrent script execution but may accumulate work during repeated failures. Add queue-depth/latency instrumentation and coalesce redundant per-app centering requests.
5. **Observer retry timer:** `Centered/WindowObserver.swift:13-15, 159-220`. Retry work is bounded per PID, but a single timer scans all pending PIDs. Measure with many running apps and ensure exhausted partial subscriptions are surfaced in diagnostics.

## Recommended remediation order

1. Fix C-01 so CI compiles.
2. Fix C-02's display geometry arithmetic.
3. Fix C-04 and C-05 to prevent focus disruption and wrong-window centering.
4. Fix C-03 and C-06 for bulk and secondary-window correctness.
5. Fix C-07 and C-08 for reliable enabled state and observer lifecycle.
6. Fix C-09 and C-10 for persistence integrity and compiler compatibility.
7. Add the regression tests described above, then address C-11 through C-16.

## Verification boundary

At this revision, GitHub Actions **does not pass**. The build log confirms the C-01 compile error in `HotKey.swift:326`. Static findings C-02 through C-16 still require their listed regression tests. No claim is made that multi-monitor behavior, Accessibility notification semantics, Keychain failure handling, or app focus behavior has been runtime-verified.
