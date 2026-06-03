import Cocoa
import Combine

@MainActor
class ViewController: NSViewController {

    private lazy var appDelegate: AppDelegate? = {
        NSApplication.shared.delegate as? AppDelegate
    }()

    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []

    @IBOutlet weak var toggleSwitch: NSSwitch!
    @IBOutlet weak var statusIndicator: NSImageView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNotifications()
        setupReactiveBindings()
        updateUI()
    }

    deinit {
        removeNotificationObservers()
    }

    // MARK: - Setup

    private func setupNotifications() {
        let nc = NotificationCenter.default
        
        let appStateObserver = nc.addObserver(
            forName: .appStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateUI()
        }
        
        let hotkeyObserver = nc.addObserver(
            forName: .hotkeyPressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateUI()
        }
        
        notificationObservers = [appStateObserver, hotkeyObserver]
    }

    private func setupReactiveBindings() {
        // If AppDelegate has a publisher, uncomment this for reactive updates:
        // appDelegate?.statePublisher
        //     .receive(on: DispatchQueue.main)
        //     .sink { [weak self] _ in self?.updateUI() }
        //     .store(in: &cancellables)
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

    // MARK: - Cleanup

    private func removeNotificationObservers() {
        let nc = NotificationCenter.default
        notificationObservers.forEach { observer in
            nc.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
}
