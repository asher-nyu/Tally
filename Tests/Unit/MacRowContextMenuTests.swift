#if os(macOS)
import AppKit
import Testing
@testable import Tally

@MainActor
struct MacRowContextMenuTests {
    @Test func nativeTargetUsesDistinctSelectorAndDispatchesActionOnce() async throws {
        var invocations = 0
        let coordinator = MacRowContextMenuCoordinator()
        coordinator.items = [.action(title: "Edit…", action: { invocations += 1 })]
        let menu = try #require(coordinator.makeMenu())
        let item = try #require(menu.items.first)

        try dispatch(item)
        #expect(invocations == 0)
        await finishQueuedActions()
        #expect(invocations == 1)
    }

    @Test func disabledActionDoesNotInvokeItsClosure() async throws {
        var invocations = 0
        let coordinator = MacRowContextMenuCoordinator()
        coordinator.items = [.action(title: "Open website", isEnabled: false, action: { invocations += 1 })]
        let menu = try #require(coordinator.makeMenu())
        let item = try #require(menu.items.first)
        #expect(!item.isEnabled)

        try dispatch(item)
        await finishQueuedActions()
        #expect(invocations == 0)
    }

    @Test func existingMenuKeepsItsOriginalActionWhenRowUpdates() async throws {
        var originalInvocations = 0
        var replacementInvocations = 0
        let coordinator = MacRowContextMenuCoordinator()
        coordinator.items = [.action(title: "Edit…", action: { originalInvocations += 1 })]
        let originalMenu = try #require(coordinator.makeMenu())
        let originalItem = try #require(originalMenu.items.first)

        coordinator.items = [.action(title: "Edit…", action: { replacementInvocations += 1 })]
        let replacementMenu = try #require(coordinator.makeMenu())
        let replacementItem = try #require(replacementMenu.items.first)
        try dispatch(originalItem)
        await finishQueuedActions()
        #expect(originalInvocations == 1)
        #expect(replacementInvocations == 0)

        try dispatch(replacementItem)
        await finishQueuedActions()
        #expect(originalInvocations == 1)
        #expect(replacementInvocations == 1)
    }

    private func dispatch(_ item: NSMenuItem) throws {
        let selector = try #require(item.action)
        // A method named perform(_:) can accidentally bind the inherited
        // NSObject.perform(_:) overload, producing performSelector: instead.
        try #require(NSStringFromSelector(selector) == "invokeMenuAction:")
        let target = try #require(item.target as? NSObject)
        try #require(target.responds(to: selector))
        #expect(NSApplication.shared.sendAction(selector, to: target, from: item))
    }

    private func finishQueuedActions() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif
