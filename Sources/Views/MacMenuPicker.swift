#if os(macOS)
import AppKit
import SwiftUI

/// A native menu picker whose accessibility actions open the same menu as a click.
struct MacMenuPicker: NSViewRepresentable {
    let label: String
    let options: [String]
    let identifier: String
    @Binding private var selection: Int
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ label: String,
        options: [String],
        selection: Binding<Int>,
        identifier: String
    ) {
        self.label = label
        self.options = options
        self.identifier = identifier
        _selection = selection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = AccessiblePopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if button.itemTitles != options {
            button.removeAllItems()
            button.addItems(withTitles: options)
        }
        if options.indices.contains(selection) {
            button.selectItem(at: selection)
        } else {
            button.select(nil)
        }
        button.isEnabled = isEnabled && !options.isEmpty
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSPopUpButton,
        context: Context
    ) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        return CGSize(width: min(ideal.width, width ?? ideal.width), height: ideal.height)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem >= 0 else { return }
            selection.wrappedValue = sender.indexOfSelectedItem
        }
    }
}

final class AccessiblePopUpButton: NSPopUpButton {
    private var isOpeningMenu = false
    private lazy var sizingButton = NSPopUpButton(frame: .zero, pullsDown: false)

    override var intrinsicContentSize: NSSize {
        // NSPopUpButton normally sizes its closed control for the widest menu
        // item. Measure the selected title with the same native button chrome
        // so short selections do not retain the space of longer alternatives.
        let selectedTitle = titleOfSelectedItem ?? ""
        if sizingButton.itemTitles != [selectedTitle] {
            sizingButton.removeAllItems()
            sizingButton.addItem(withTitle: selectedTitle)
        }
        sizingButton.font = font
        sizingButton.controlSize = controlSize
        sizingButton.bezelStyle = bezelStyle
        sizingButton.isBordered = isBordered
        return sizingButton.intrinsicContentSize
    }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        openMenu()
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformPress)
            || selector == #selector(accessibilityPerformShowMenu) {
            return isEnabled && numberOfItems > 0
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    private func openMenu() -> Bool {
        guard isEnabled, numberOfItems > 0, window != nil else { return false }
        guard !isOpeningMenu else { return true }
        isOpeningMenu = true
        // Menu tracking runs a modal loop. Return from the accessibility action
        // first so its caller can receive a response and select a menu item.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isOpeningMenu = false }
            guard self.isEnabled, self.numberOfItems > 0, self.window != nil,
                  let popupCell = self.cell as? NSPopUpButtonCell else { return }
            popupCell.performClick(withFrame: self.bounds, in: self)
        }
        return true
    }
}
#endif
