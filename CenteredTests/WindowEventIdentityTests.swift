import Testing
@testable import Centered

@Suite("Observer event window identity")
struct WindowEventIdentityTests {
    private func state(_ id: String, minimized: Bool? = false) -> WindowEventState<String> {
        WindowEventState(identity: id, isMinimized: minimized)
    }

    @Test func createdEventUsesItsWindowNotTheOldFocus() {
        #expect(WindowEventResolver.resolve(
            event: .created, eventWindow: state("B"), focusedWindow: state("A"),
            previous: [state("A")], current: [state("B"), state("A")]
        ) == "B")
    }

    @Test func creationDiffDoesNotDependOnWindowListOrder() {
        for current in [[state("A"), state("B")], [state("B"), state("A")]] {
            #expect(WindowEventResolver.resolve(
                event: .created, eventWindow: nil, focusedWindow: state("A"),
                previous: [state("A")], current: current
            ) == "B")
        }
    }

    @Test func ambiguousCreationsAreSkipped() {
        #expect(WindowEventResolver.resolve(
            event: .created, eventWindow: nil, focusedWindow: state("A"),
            previous: [state("A")], current: [state("A"), state("B"), state("C")]
        ) == nil)
    }

    @Test func missingBaselineOrIncompleteSnapshotIsNotGuessed() {
        #expect(WindowEventResolver.resolve(
            event: .created, eventWindow: nil, focusedWindow: state("A"),
            previous: nil, current: [state("A")]
        ) == nil)
        #expect(WindowEventResolver.resolve(
            event: .created, eventWindow: nil, focusedWindow: state("A"),
            previous: [state("A")], current: nil
        ) == nil)
    }

    @Test func restorationUsesTheMinimizedStateTransition() {
        #expect(WindowEventResolver.resolve(
            event: .restored, eventWindow: nil, focusedWindow: state("A"),
            previous: [state("A"), state("B", minimized: true)],
            current: [state("B"), state("A")]
        ) == "B")
    }

    @Test func directRestorationWorksWithoutAnApplicationSnapshot() {
        #expect(WindowEventResolver.resolve(
            event: .restored, eventWindow: state("B"), focusedWindow: state("A"),
            previous: nil, current: nil
        ) == "B")
    }

    @Test func focusEventsUseOnlyTheFocusedWindow() {
        #expect(WindowEventResolver.resolve(
            event: .focused, eventWindow: state("A"), focusedWindow: state("B"),
            previous: [state("A")], current: [state("A"), state("B")]
        ) == "B")
        #expect(WindowEventResolver.resolve(
            event: .focused, eventWindow: state("A"), focusedWindow: nil,
            previous: nil, current: [state("A")]
        ) == nil)
    }

    @Test func minimizedEventWindowIsNotCentered() {
        #expect(WindowEventResolver.resolve(
            event: .created, eventWindow: state("B", minimized: true), focusedWindow: state("A"),
            previous: nil, current: nil
        ) == nil)
    }

    @Test func minimizationOnlyRefreshesState() {
        #expect(WindowEventResolver.resolve(
            event: .other, eventWindow: state("B", minimized: true), focusedWindow: state("A"),
            previous: [state("B")], current: [state("B", minimized: true)]
        ) == nil)
    }
}
