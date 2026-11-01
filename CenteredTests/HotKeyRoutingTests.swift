import Testing
import Cocoa
import Carbon.HIToolbox
@testable import Centered

@Suite("Carbon hotkey event routing")
struct HotKeyRoutingTests {
    @Test func eachOfSixHandlersAcceptsOnlyItsOwnEvent() {
        let signature: UInt32 = 0x43656E74
        let routes = (1...6).map { HotKeyEventRoute(signature: signature, id: UInt32($0)) }
        for firedID in UInt32(1)...UInt32(6) {
            let statuses = routes.map { $0.status(forSignature: signature, id: firedID) }
            #expect(statuses.filter { $0 == noErr }.count == 1)
            #expect(statuses[Int(firedID - 1)] == noErr)
            #expect(statuses.filter { $0 == OSStatus(eventNotHandledErr) }.count == 5)
        }
    }

    @Test func differentSignatureIsNotConsumed() {
        let route = HotKeyEventRoute(signature: 0x43656E74, id: 1)
        #expect(route.status(forSignature: 0, id: 1) == OSStatus(eventNotHandledErr))
    }

    @Test func unknownIDIsNotConsumed() {
        let route = HotKeyEventRoute(signature: 0x43656E74, id: 1)
        #expect(route.status(forSignature: 0x43656E74, id: 99) == OSStatus(eventNotHandledErr))
    }

    @MainActor
    @Test func rebindingWhileDisabledDoesNotActivate() throws {
        let hotKey = HotKey(binding: .centerActive)
        defer { hotKey.deactivate() }
        try hotKey.rebind(to: .centerAll)
        #expect(hotKey.binding == .centerAll)
        #expect(!hotKey.isActive)
    }
}
