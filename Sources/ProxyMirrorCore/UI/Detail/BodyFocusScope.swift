import SwiftUI
import AppKit

/// Global menu notifications must only change the inspector in the key window.
final class BodyWindowReference {
    weak var window: NSWindow?
}

struct BodyWindowAnchor: NSViewRepresentable {
    let reference: BodyWindowReference
    func makeNSView(context: Context) -> Anchor { Anchor(reference: reference) }
    func updateNSView(_ view: Anchor, context: Context) { reference.window = view.window }

    final class Anchor: NSView {
        let reference: BodyWindowReference
        init(reference: BodyWindowReference) { self.reference = reference; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reference.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
