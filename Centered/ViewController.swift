import Cocoa

@MainActor
class ViewController: NSViewController {

    private lazy var appDelegate: AppDelegate? = {
        NSApplication.shared.delegate as? AppDelegate
    }()


    @IBOutlet weak var toggleSwitch: NSSwitch!
    @IBOutlet weak var statusIndicator: NSImageView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNotifications()
        updateUI()
    }

    // MARK: - Setup

    private func setupNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(notificationReceived(_:)), name: .appStateChanged, object: nil)
        center.addObserver(self, selector: #selector(notificationReceived(_:)), name: .hotkeyPressed, object: nil)
    }

    @objc private func notificationReceived(_ notification: Notification) {
        updateUI()
    }

    // MARK: - Actions

    @IBAction func toggleSwitchChanged(_ sender: NSSwitch) {
        guard let appDelegate else { return }
        sender.state == .on ? appDelegate.enableApp() : appDelegate.disableApp()
        updateUI()
    }

    // MARK: - UI Updates

    @objc private func updateUI() {
        guard let enabled = appDelegate?.isEnabled else {
            updateUIForUnknownState()
            return
        }
        
        toggleSwitch.isEnabled = true
        toggleSwitch.state = enabled ? .on : .off
        
        let config = getStatusConfiguration(enabled: enabled)
        setStatus(symbol: config.symbol, description: config.description, color: config.color)
    }

    private func updateUIForUnknownState() {
        toggleSwitch.isEnabled = false
        setStatus(symbol: "circle.fill", description: "Unknown", color: .gray)
    }

    private func getStatusConfiguration(enabled: Bool) -> (symbol: String, description: String, color: NSColor) {
        return (
            symbol: "circle.fill",
            description: enabled ? "Enabled" : "Disabled",
            color: enabled ? .systemGreen : .systemRed
        )
    }

    private func setStatus(symbol: String, description: String, color: NSColor) {
        statusIndicator.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: description
        )
        statusIndicator.contentTintColor = color
    }

}
