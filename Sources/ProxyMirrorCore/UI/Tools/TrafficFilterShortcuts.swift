import AppKit
import SwiftUI

/// Kept independent of app-wide Commands: only a mounted filter sheet's key window consumes these keys.
enum TrafficFilterShortcut: Equatable {
    case addCondition, addGroup, previous, next, toggleColor, search, cancel
    static func match(key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, code == 53 { return .cancel }
        if flags == [.command, .shift], key.lowercased() == "n" { return .addGroup }
        guard flags == [.command] else { return nil }
        switch key.lowercased() {
        case "n": return .addCondition
        case "b": return .toggleColor
        case "f": return .search
        default:
            if code == 126 { return .previous }
            if code == 125 { return .next }
            return nil
        }
    }
    static func nextIndex(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta < 0 ? count - 1 : 0 }
        return min(count - 1, max(0, current + delta))
    }
}

@MainActor
struct TrafficFilterKeyHandler: NSViewRepresentable {
    let action: (TrafficFilterShortcut) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        var action: (TrafficFilterShortcut) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        init(action: @escaping (TrafficFilterShortcut) -> Void) { self.action = action }
        func attach(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, window.isVisible, window.isKeyWindow,
                      (event.window ?? NSApp.keyWindow) === window,
                      let command = TrafficFilterShortcut.match(key: event.charactersIgnoringModifiers ?? "", code: event.keyCode, modifiers: event.modifierFlags) else { return event }
                self.action(command)
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
