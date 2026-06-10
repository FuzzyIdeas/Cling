import Cocoa
import Lowtech
import OSLog

private let log = Logger(subsystem: clingSubsystem, category: "DragDropSimulator")

private let DD = "[DragDrop]"

// MARK: - DragSourceView

final class DragSourceView: NSView, NSDraggingSource {
    override var acceptsFirstResponder: Bool { true }

    var fileURLs: [URL] = []
    var onMouseDown: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onSessionEnded: ((NSDragOperation) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !fileURLs.isEmpty else {
            log.warning("\(DD) view.mouseDragged with empty fileURLs — drag will have no payload")
            super.mouseDragged(with: event)
            return
        }

        let blank = NSImage(size: NSSize(width: 1, height: 1))
        let items: [NSDraggingItem] = fileURLs.enumerated().map { i, url in
            let pb = NSPasteboardItem()
            pb.setString(url.absoluteString, forType: .fileURL)
            let item = NSDraggingItem(pasteboardWriter: pb)

            if i < 2 {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 64, height: 64)
                let offset = CGFloat(i) * 4
                let frame = NSRect(
                    x: bounds.midX - 32 + offset,
                    y: bounds.midY - 32 - offset,
                    width: 64, height: 64
                )
                item.setDraggingFrame(frame, contents: img)
            } else {
                item.setDraggingFrame(NSRect(x: 0, y: 0, width: 1, height: 1), contents: blank)
            }
            return item
        }

        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only. Advertising `.link` lets Finder resolve the drop to "make alias"
        // (and `.generic` can become a move), which is what produced stray alias files.
        // SwiftUI's `.draggable(url)` used for manual drags offers copy only too, so this
        // keeps the synthesized drag behaving identically.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStart?()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {}

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onSessionEnded?(operation)
    }
}

// MARK: - DragDropSimulator

@MainActor
final class DragDropSimulator {
    static let shared = DragDropSimulator()

    func performDrop(fileURLs urls: [URL], to dropCG: CGPoint, activating app: NSRunningApplication? = nil) {
        guard !urls.isEmpty else {
            log.warning("\(DD) abort: no URLs")
            return
        }

        cleanup()
        mouseDownReceived = false
        dragSessionStarted = false

        let startNS = NSEvent.mouseLocation
        let startCG = Self.nsToCG(startNS)

        // Bigger panel so the cursor can wander a few px during the synthesized drag without
        // leaving our hit-test area before mouseDragged fires.
        let panelSize: CGFloat = 40
        let panelRect = NSRect(
            x: startNS.x - panelSize / 2,
            y: startNS.y - panelSize / 2,
            width: panelSize, height: panelSize
        )

        let view = DragSourceView(frame: NSRect(origin: .zero, size: NSSize(width: panelSize, height: panelSize)))
        view.fileURLs = urls
        view.onMouseDown = { [weak self] in
            self?.mouseDownReceived = true
        }
        view.onDragStart = { [weak self] in
            self?.dragSessionStarted = true
            // Hide the helper panel so it can't block subsequent drag/drop hit-testing.
            self?.panel?.orderOut(nil)
        }
        view.onSessionEnded = { [weak self] _ in
            app?.activate()
            mainAsyncAfter(ms: 30) { self?.cleanup() }
        }

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.displayIfNeeded()

        self.view = view
        self.panel = panel

        // Watchdog: if no drag session starts within ~1s, log + clean up so we don't leak the panel.
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            if !dragSessionStarted {
                let mouseDownReceived = self.mouseDownReceived
                log.error("\(DD) WATCHDOG: drag session never started after 1s (mouseDown received=\(mouseDownReceived))")
                cleanup()
            }
        }

        // One runloop tick lets the window server map the panel before we synthesize HID events.
        DispatchQueue.main.async {
            DispatchQueue.global(qos: .userInteractive).async {
                Self.synthesizeDrag(from: startCG, to: dropCG)
            }
        }
    }

    private var panel: NSPanel?
    private var view: DragSourceView?
    private var watchdog: Task<Void, Never>?
    private var mouseDownReceived = false
    private var dragSessionStarted = false

    private nonisolated static func synthesizeDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Give the window server time to actually map + present our helper panel.
        usleep(120_000)

        post(.leftMouseDown, at: start, source: source)
        usleep(60000)

        // Initial micro-drag stays inside the panel so mouseDragged is delivered to our view.
        let triggerPoint = CGPoint(x: start.x + 4, y: start.y + 4)
        post(.leftMouseDragged, at: triggerPoint, source: source)

        // Give beginDraggingSession time to take over before we fan out toward the target.
        usleep(120_000)

        let steps = 40
        for i in 1 ... steps {
            let linear = CGFloat(i) / CGFloat(steps)
            let t = Self.easeInOutCubic(linear)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            post(.leftMouseDragged, at: CGPoint(x: x, y: y), source: source)
            usleep(10000)
        }
        // Settle so destination has time to highlight + accept.
        usleep(120_000)
        post(.leftMouseUp, at: end, source: source)
    }

    private nonisolated static func post(_ type: CGEventType, at point: CGPoint, source: CGEventSource?) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            log.error("\(DD) failed to create CGEvent type=\(type.rawValue)")
            return
        }
        e.post(tap: .cghidEventTap)
    }

    private nonisolated static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private nonisolated static func nsToCG(_ p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    private func cleanup() {
        watchdog?.cancel()
        watchdog = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

}
