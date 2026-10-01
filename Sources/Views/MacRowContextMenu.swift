#if os(macOS)
import AppKit
import SwiftUI

@MainActor
enum MacRowContextMenuItem {
    case action(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @MainActor () -> Void
    )
    case separator
}

/// Hosts the existing row controls while AppKit presents their contextual menu.
@MainActor
struct MacRowContextMenu<Content: View>: NSViewRepresentable {
    let items: [MacRowContextMenuItem]
    private let content: Content

    init(items: [MacRowContextMenuItem], @ViewBuilder content: () -> Content) {
        self.items = items
        self.content = content()
    }

    func makeCoordinator() -> MacRowContextMenuCoordinator {
        MacRowContextMenuCoordinator()
    }

    func makeNSView(context: Context) -> MacRowContextMenuHostingView {
        let view = MacRowContextMenuHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = [.intrinsicContentSize]
        view.safeAreaRegions = []
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: MacRowContextMenuHostingView, context: Context) {
        // Forward presentation values individually. Copying the complete
        // environment can also carry the outer hierarchy's accessibility
        // attachment context across this independent hosting boundary.
        let environment = context.environment
        let root = AnyView(
            content
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.locale, environment.locale)
                .environment(\.calendar, environment.calendar)
                .environment(\.timeZone, environment.timeZone)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.isEnabled, environment.isEnabled)
                .environment(\.controlSize, environment.controlSize)
                .font(environment.font)
        )
        context.coordinator.items = items
        context.coordinator.isEnabled = context.environment.isEnabled
        context.coordinator.measurementController.rootView = root
        nsView.rootView = root
        nsView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MacRowContextMenuHostingView,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let idealWidth = intrinsic.width.isFinite && intrinsic.width >= 0 ? intrinsic.width : 0
        let width = proposedWidth ?? idealWidth
        let height = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? CGFloat.greatestFiniteMagnitude
        let measured = context.coordinator.measurementController.sizeThatFits(
            in: CGSize(width: width, height: height)
        )
        guard measured.height.isFinite else { return nil }
        return CGSize(width: width, height: max(0, measured.height))
    }
}

@MainActor
final class MacRowContextMenuHostingView: NSHostingView<AnyView> {
    var menuProvider: (() -> NSMenu?)?
    private var presentedMenu: NSMenu?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = menuProvider?() ?? super.menu(for: event)
        // Keep the original menu and its targets alive through AppKit's
        // contextual-menu tracking and native menu-item copies.
        presentedMenu = menu
        return menu
    }
}

@MainActor
final class MacRowContextMenuCoordinator {
    var items: [MacRowContextMenuItem] = []
    var isEnabled = true
    private var actionTargets: [MacRowContextMenuAction] = []

    // NSHostingView has no public proposal-based measurement API. This
    // controller remains unmounted and measures the same content at the
    // proposed width, so multiline rows retain their natural height.
    let measurementController = NSHostingController(rootView: AnyView(EmptyView()))

    func makeMenu() -> NSMenu? {
        guard isEnabled, !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var targets: [MacRowContextMenuAction] = []
        for item in items {
            switch item {
            case .separator:
                if menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
            case let .action(title, systemImage, enabled, _, action):
                let target = MacRowContextMenuAction(action: action)
                targets.append(target)
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(MacRowContextMenuAction.invokeMenuAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = target
                // NSMenuItem.target is weak. Retain this action snapshot for
                // the menu's lifetime, even if SwiftUI updates the row.
                menuItem.representedObject = target
                menuItem.isEnabled = enabled
                if let systemImage {
                    menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
                }
                menu.addItem(menuItem)
            }
        }
        if menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.numberOfItems - 1)
        }
        // Also retain targets independently of the menu items. AppKit can
        // copy contextual menu items while presenting the native menu.
        actionTargets = targets
        return menu.items.isEmpty ? nil : menu
    }
}

@MainActor
private final class MacRowContextMenuAction: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invokeMenuAction(_ sender: NSMenuItem) {
        guard sender.isEnabled else { return }
        // Present sheets after menu tracking unwinds, rather than while
        // AppKit is still dismissing the contextual menu.
        let action = action
        DispatchQueue.main.async {
            action()
        }
    }
}
#endif
