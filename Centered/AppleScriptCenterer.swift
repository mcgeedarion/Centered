import Cocoa
import os.log

private let appleScriptLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Centered",
    category: "AppleScriptCenterer"
)

private let allowedBundleIDCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
)
private let maxBundleIDLength: Int = 255

private let appleScriptQueue = DispatchQueue(
    label: "com.centered.applescript",
    qos: .userInitiated
)

struct AppleScriptCenterer {

    /// Validates that a bundle ID matches Apple's format requirements and security constraints.
    /// - Parameter bundleID: The bundle identifier to validate
    /// - Returns: `true` if the bundle ID is valid, `false` otherwise
    static func isValidBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty &&
        bundleID.count <= maxBundleIDLength &&
        bundleID.unicodeScalars.allSatisfy { allowedBundleIDCharacters.contains($0) }
    }

    /// Centers the frontmost window of the given application using AppleScript.
    /// Falls back to alternative positioning if animation is unsupported.
    /// - Parameter app: The running application whose window should be centered
    static func centerFrontmostWindow(of app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else {
            appleScriptLogger.debug("AppleScript fallback skipped: no bundle ID for pid \(app.processIdentifier)")
            return
        }
        executeCentering(bundleID: bundleID, app: app)
    }

    /// Executes the window centering operation after validating the bundle ID and process.
    /// - Parameters:
    ///   - bundleID: The validated bundle identifier
    ///   - app: The running application to verify and center
    private static func executeCentering(bundleID: String, app: NSRunningApplication) {
        guard validateBundleID(bundleID, app: app) else {
            return
        }

        let script = generateCenteringScript(bundleID: bundleID)
        appleScriptQueue.async {
            executeAppleScript(script, bundleID: bundleID)
        }
    }

    /// Validates both the bundle ID format and that it matches the running process.
    /// - Parameters:
    ///   - bundleID: The bundle identifier to validate
    ///   - app: The running application to verify against
    /// - Returns: `true` if all validations pass, `false` otherwise
    private static func validateBundleID(_ bundleID: String, app: NSRunningApplication) -> Bool {
        guard isValidBundleID(bundleID) else {
            appleScriptLogger.debug("Rejected bundle ID with invalid format")
            return false
        }

        guard NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier == app.processIdentifier })
        else {
            appleScriptLogger.debug("Rejected bundle ID \(bundleID, privacy: .public): pid mismatch (possible spoof)")
            return false
        }

        return true
    }

    /// Generates the AppleScript code for centering a window.
    /// - Parameter bundleID: The bundle identifier of the target application
    /// - Returns: The complete AppleScript as a string
    private static func generateCenteringScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
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
    }

    /// Executes the provided AppleScript and logs any errors that occur.
    /// - Parameters:
    ///   - script: The AppleScript code to execute
    ///   - bundleID: The bundle identifier for logging context
    private static func executeAppleScript(_ script: String, bundleID: String) {
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)

        if let error {
            let errorCode = error[NSAppleScript.errorNumber] as? NSNumber ?? -1
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            appleScriptLogger.debug(
                "AppleScript error (\(bundleID, privacy: .public)): [\(errorCode)] \(errorMessage)"
            )
        }
    }
}
