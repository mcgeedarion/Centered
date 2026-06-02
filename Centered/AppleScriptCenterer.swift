import Cocoa
import os.log

private let appleScriptLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "AppleScriptCenterer"
)

private let kBundleIDAllowedChars = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
)
private let kBundleIDMaxLength: Int = 255

private let appleScriptQueue = DispatchQueue(
    label: "com.centered.applescript",
    qos: .userInitiated
)

struct AppleScriptCenterer {

    static func isValidBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty &&
        bundleID.count <= kBundleIDMaxLength &&
        bundleID.unicodeScalars.allSatisfy { kBundleIDAllowedChars.contains($0) }
    }

    static func centerFrontmostWindow(of app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else {
            appleScriptLogger.debug("AppleScript fallback skipped: no bundle ID for pid \(app.processIdentifier)")
            return
        }
        executeCentering(bundleID: bundleID, app: app)
    }

    static func executeCentering(bundleID: String, app: NSRunningApplication) {
        guard isValidBundleID(bundleID) else {
            appleScriptLogger.debug("Rejected bundle ID with invalid format")
            return
        }
        guard NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier == app.processIdentifier })
        else {
            appleScriptLogger.debug("Rejected bundle ID \(bundleID, privacy: .public): pid mismatch (possible spoof)")
            return
        }

        let script = """
        tell application id \"\(bundleID)\"
            activate
            try
                set win to front window
                set winBounds to bounds of win
                tell application "System Events" to tell first desktop
                    set screenBounds to bounds
                    set screenWidth  to item 3 of screenBounds
                    set screenHeight to item 4 of screenBounds
                end tell
                set winWidth  to item 3 of winBounds - item 1 of winBounds
                set winHeight to item 4 of winBounds - item 2 of winBounds
                set newX to (screenWidth  - winWidth)  / 2
                set newY to (screenHeight - winHeight) / 2
                try
                    set bounds of win to {newX, newY, newX + winWidth, newY + winHeight} with animation
                on error
                    set position of win to {newX, newY}
                    set size     of win to {winWidth, winHeight}
                end try
            end try
        end tell
        """
        appleScriptQueue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                appleScriptLogger.debug("AppleScript error (\(bundleID, privacy: .public)): \(error)")
            }
        }
    }
}
