#if os(macOS)
import SwiftUI

/// Names the AppKit content group that hosts a SwiftUI document window.
/// SwiftUI's view labels do not reach this outer accessibility container.
struct WindowAccessibilityLabel: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> LabelView {
        let view = LabelView()
        view.label = label
        return view
    }

    func updateNSView(_ view: LabelView, context: Context) {
        view.label = label
        view.updateLabel()
    }

    final class LabelView: NSView {
        var label = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateLabel()
        }

        func updateLabel() {
            window?.contentView?.setAccessibilityLabel(label)
        }
    }
}
#endif
