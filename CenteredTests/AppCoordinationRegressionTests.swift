import Testing
import Cocoa
@testable import Centered

@Suite("Menu section boundaries")
@MainActor
struct MenuSectionRegressionTests {
    private func item(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
    private func actions() -> [NSMenuItem] {
        [item("Status"), .separator(), item("Center Active"), item("Center All"),
         .separator(), item("Preferences")]
    }

    @Test func repeatedActionUpdatesPreserveOtherSectionsWithoutDuplicates() {
        let screen = item("Display")
        let quit = item("Quit")
        let menu = MenuState(screens: [screen], actions: actions(), system: [quit]).buildMenu()
        let expectedCount = menu.items.count
        for _ in 0..<20 {
            #expect(MenuState.replaceActions(in: menu, with: actions()))
            #expect(menu.items.count == expectedCount)
            #expect(menu.items.first === screen)
            #expect(menu.items.last === quit)
            #expect(menu.items.filter { $0.title == "Center Active" }.count == 1)
            #expect(menu.items.filter { $0.title == "Preferences" }.count == 1)
            #expect(menu.items.filter { $0.identifier == MenuState.screensEnd }.count == 1)
            #expect(menu.items.filter { $0.identifier == MenuState.actionsEnd }.count == 1)
        }
    }

    @Test func screenUpdatesPreserveActionAndSystemIdentity() {
        let action = item("Center")
        let quit = item("Quit")
        let menu = MenuState(screens: [item("Old")], actions: [action], system: [quit]).buildMenu()
        #expect(MenuState.replaceScreens(in: menu, with: [item("A"), item("B")]))
        #expect(menu.items.filter { $0 === action }.count == 1)
        #expect(menu.items.last === quit)
        #expect(MenuState.replaceActions(in: menu, with: []))
        #expect(menu.items.map { $0.title }.filter { !$0.isEmpty } == ["A", "B", "Quit"])
    }

    @Test func missingMarkersDoNotModifyTheMenu() {
        let menu = NSMenu()
        let existing = item("Existing")
        menu.addItem(existing)
        #expect(!MenuState.replaceActions(in: menu, with: actions()))
        #expect(!MenuState.replaceScreens(in: menu, with: [item("Replacement")]))
        #expect(menu.items.count == 1)
        #expect(menu.items.first === existing)
    }
}

@Suite("Stable display menu identity")
@MainActor
struct DisplayIdentityRegressionTests {
    @Test func identicalLabelsStillSelectDifferentDisplayIDs() {
        let first = NSMenuItem(title: "Identical display", action: nil, keyEquivalent: "")
        let second = NSMenuItem(title: "Identical display", action: nil, keyEquivalent: "")
        first.representedObject = NSNumber(value: UInt32(11))
        second.representedObject = NSNumber(value: UInt32(22))
        #expect(DisplaySelection.id(from: first) == 11)
        #expect(DisplaySelection.id(from: second) == 22)
        #expect(DisplaySelection.index(for: 22, among: [11, 22]) == 1)
    }

    @Test func displayReorderingAndDisconnectionDoNotMatchByNameOrIndex() {
        #expect(DisplaySelection.index(for: 22, among: [22, nil, 11]) == 0)
        #expect(DisplaySelection.index(for: 22, among: [11]) == nil)
        #expect(DisplaySelection.index(for: 22, among: []) == nil)
    }

    @Test func invalidRepresentedDisplayIDsAreRejected() {
        let item = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        item.representedObject = "Legacy display name"
        #expect(DisplaySelection.id(from: item) == nil)
        item.representedObject = NSNumber(value: UInt64(UInt32.max) + 1)
        #expect(DisplaySelection.id(from: item) == nil)
        item.representedObject = NSNumber(value: -1)
        #expect(DisplaySelection.id(from: item) == nil)
    }
}

private enum SimulatedHotKeyError: Error { case conflict }

@MainActor
private final class FakeRecoverableHotKey: RecoverableHotKey {
    var isActive = false
    var activationFails = false
    var rebindFails = false
    var activationCalls = 0
    var activationRequestedOnRebind: Bool?
    var binding = HotKeyBinding.centerActive

    func activate() throws {
        activationCalls += 1
        if activationFails { throw SimulatedHotKeyError.conflict }
        isActive = true
    }
    func deactivate() { isActive = false }
    func rebind(to binding: HotKeyBinding, activateIfNeeded: Bool) throws {
        activationRequestedOnRebind = activateIfNeeded
        if rebindFails { throw SimulatedHotKeyError.conflict }
        self.binding = binding
        if activateIfNeeded { try activate() }
    }
}

@Suite("Shortcut recovery and persistence")
@MainActor
struct ShortcutRecoveryRegressionTests {
    @Test func rebindingAnUnavailableShortcutWhileEnabledActivatesIt() throws {
        let key = FakeRecoverableHotKey()
        var saved: HotKeyBinding?
        try ShortcutRecovery.rebind(key, to: .centerAll, enabled: true) { saved = $0 }
        #expect(key.activationRequestedOnRebind == true)
        #expect(key.isActive)
        #expect(saved == .centerAll)
        #expect(ShortcutRecovery.unavailable([("Center All", key)]).isEmpty)
    }

    @Test func rebindingWhileDisabledDoesNotActivateIt() throws {
        let key = FakeRecoverableHotKey()
        var saved: HotKeyBinding?
        try ShortcutRecovery.rebind(key, to: .centerAll, enabled: false) { saved = $0 }
        #expect(key.activationRequestedOnRebind == false)
        #expect(!key.isActive)
        #expect(key.activationCalls == 0)
        #expect(saved == .centerAll)
    }

    @Test func failedRebindingDoesNotPersistTheRejectedBinding() {
        let key = FakeRecoverableHotKey()
        key.rebindFails = true
        var saved: HotKeyBinding?
        do {
            try ShortcutRecovery.rebind(key, to: .centerAll, enabled: true) { saved = $0 }
            Issue.record("Expected the simulated shortcut conflict")
        } catch {
            #expect(error is SimulatedHotKeyError)
        }
        #expect(saved == nil)
        #expect(key.binding == .centerActive)
    }

    @Test func retriesOnlyUnavailableShortcutsAndClearsRecoveredFailures() {
        let working = FakeRecoverableHotKey()
        working.isActive = true
        let recovering = FakeRecoverableHotKey()
        recovering.activationFails = true
        let keys: [(String, any RecoverableHotKey)] = [("Working", working), ("Recovering", recovering)]
        #expect(ShortcutRecovery.activateUnavailable(keys) == Set(["Recovering"]))
        #expect(working.activationCalls == 0)
        recovering.activationFails = false
        #expect(ShortcutRecovery.activateUnavailable(keys).isEmpty)
        #expect(recovering.activationCalls == 2)
        #expect(working.activationCalls == 0)
    }

    @Test func oneConflictDoesNotPreventOtherShortcutsFromActivating() {
        let failed = FakeRecoverableHotKey()
        failed.activationFails = true
        let successful = FakeRecoverableHotKey()
        let keys: [(String, any RecoverableHotKey)] = [("Failed", failed), ("Successful", successful)]
        #expect(ShortcutRecovery.activateUnavailable(keys) == Set(["Failed"]))
        #expect(successful.isActive)
        #expect(successful.activationCalls == 1)
    }
}
