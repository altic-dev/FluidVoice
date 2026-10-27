import AppKit
import SwiftUI

/// Opt-in click-away cancellation for a native sheet. The click is consumed so
/// dismissing settings cannot also activate a control in the underlying window.
struct FluidSheetOutsideDismiss: NSViewRepresentable {
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        view.onCancel = self.onCancel
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onCancel = self.onCancel
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onCancel: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.stopMonitoring()
            guard self.window != nil else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let sheet = self.window,
                      let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet,
                      sheet.isVisible,
                      let eventWindow = event.window,
                      eventWindow === parent || eventWindow === sheet
                else { return event }
                let point = eventWindow.convertPoint(toScreen: event.locationInWindow)
                guard parent.frame.contains(point), !sheet.frame.contains(point) else { return event }
                self.stopMonitoring()
                self.onCancel?()
                return nil
            }
        }

        func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit { self.stopMonitoring() }
    }
}
