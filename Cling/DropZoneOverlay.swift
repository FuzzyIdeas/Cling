import Cocoa
import Lowtech
import SwiftUI

// MARK: - DropZoneOverlay

@MainActor
final class DropZoneOverlay {
    static let shared = DropZoneOverlay()

    // Mouseless first overlay: 9 home-row column keys × 9 home-row row keys.
    static let mouselessColumns: [Character] = Array("asdfghjkl")
    static let mouselessRows: [Character] = Array("asdfghjkl")

    /// Single-letter drill-down second overlay.
    static let singleLetterRows: [[Character]] = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm"),
    ]

    var isPresenting: Bool {
        panel != nil
    }

    func present(onSelect: @escaping (CGPoint) -> Void, onCancel: @escaping () -> Void) {
        dismiss(restoreHiddenWindow: true)

        onFinalSelect = onSelect
        self.onCancel = onCancel

        // Hide Cling visually so the user can see what's behind it through the overlay.
        if let win = AppDelegate.shared.mainWindow {
            hiddenWindow = win
            hiddenOriginalAlpha = win.alphaValue
            win.alphaValue = 0
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        showOverlay(in: screen.frame, mode: .mouseless(selectedColumn: nil), cornerRadius: 0)

        // Catch Esc even when Cling is not the active app.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 0x35 else { return }
            Task { @MainActor in DropZoneOverlay.shared.dismissIfPresenting() }
        }
    }

    func dismissIfPresenting() {
        guard isPresenting else { return }
        let cb = onCancel
        dismiss(restoreHiddenWindow: true)
        cb?()
    }

    func dismiss(restoreHiddenWindow: Bool = true) {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let m = globalKeyMonitor {
            NSEvent.removeMonitor(m)
            globalKeyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        if restoreHiddenWindow, let win = hiddenWindow {
            win.alphaValue = hiddenOriginalAlpha
        }
        hiddenWindow = nil
        onFinalSelect = nil
        onCancel = nil
    }

    private enum Mode {
        case mouseless(selectedColumn: Int?)
        case singleLetter
    }

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var currentRect: NSRect = .zero
    private var mode: Mode = .mouseless(selectedColumn: nil)
    private var onFinalSelect: ((CGPoint) -> Void)?
    private var onCancel: (() -> Void)?
    private var hiddenWindow: NSWindow?
    private var hiddenOriginalAlpha: CGFloat = 1

    private static func mouselessCellRect(in rect: NSRect, col: Int, row: Int) -> NSRect {
        let cols = mouselessColumns.count
        let rs = mouselessRows.count
        let cellW = rect.width / CGFloat(cols)
        let cellH = rect.height / CGFloat(rs)
        // Row 0 (q) is rendered at the TOP of the rect; flip for NS (bottom-left origin).
        let yNS = rect.maxY - CGFloat(row + 1) * cellH
        let xNS = rect.minX + CGFloat(col) * cellW
        return NSRect(x: xNS, y: yNS, width: cellW, height: cellH)
    }

    private static func singleLetterZoneRect(in rect: NSRect, for ch: Character) -> NSRect? {
        for (rowIdx, row) in singleLetterRows.enumerated() {
            guard let colIdx = row.firstIndex(of: ch) else { continue }
            let rowH = rect.height / CGFloat(singleLetterRows.count)
            let colW = rect.width / CGFloat(row.count)
            let yNS = rect.maxY - CGFloat(rowIdx + 1) * rowH
            let xNS = rect.minX + CGFloat(colIdx) * colW
            return NSRect(x: xNS, y: yNS, width: colW, height: rowH)
        }
        return nil
    }

    private func showOverlay(in nsRect: NSRect, mode: Mode, cornerRadius: CGFloat) {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil

        currentRect = nsRect
        self.mode = mode

        let hostView: NSView = switch mode {
        case let .mouseless(sel):
            NSHostingView(
                rootView:
                MouselessGridView(
                    columns: Self.mouselessColumns.map(String.init),
                    rows: Self.mouselessRows.map(String.init),
                    selectedColumn: sel,
                    cornerRadius: cornerRadius
                )
            )
        case .singleLetter:
            NSHostingView(
                rootView:
                DropZoneOverlayView(
                    rows: Self.singleLetterRows.map { $0.map(String.init) },
                    cornerRadius: cornerRadius
                )
            )
        }
        hostView.frame = NSRect(origin: .zero, size: nsRect.size)
        hostView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: nsRect,
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
        panel.contentView = hostView
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        // Esc cancels at any phase.
        if event.keyCode == 0x35 {
            let cb = onCancel
            dismiss(restoreHiddenWindow: true)
            cb?()
            return nil
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard let ch = chars.first else { return nil }

        switch mode {
        case .mouseless(.none):
            guard let colIdx = Self.mouselessColumns.firstIndex(of: ch) else { return nil }
            showOverlay(in: currentRect, mode: .mouseless(selectedColumn: colIdx), cornerRadius: 0)

        case let .mouseless(.some(colIdx)):
            guard let rowIdx = Self.mouselessRows.firstIndex(of: ch) else { return nil }
            let cellRect = Self.mouselessCellRect(in: currentRect, col: colIdx, row: rowIdx)
            // Drill into the single-letter overlay confined to the chosen cell.
            showOverlay(in: cellRect, mode: .singleLetter, cornerRadius: 12)

        case .singleLetter:
            guard let zoneRect = Self.singleLetterZoneRect(in: currentRect, for: ch) else { return nil }
            let centerNS = NSPoint(x: zoneRect.midX, y: zoneRect.midY)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cg = CGPoint(x: centerNS.x, y: primaryHeight - centerNS.y)
            let cb = onFinalSelect
            dismiss(restoreHiddenWindow: false)
            cb?(cg)
        }
        return nil
    }

}

// MARK: - DropZoneOverlayView

struct DropZoneOverlayView: View {
    let rows: [[String]]
    var cornerRadius: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 2) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, letter in
                            ZoneCell(letter: letter)
                        }
                    }
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .ignoresSafeArea()
    }
}

// MARK: - ZoneCell

private struct ZoneCell: View {
    let letter: String

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Text(letter.uppercased())
                .font(.system(size: max(12, side * 0.55), weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: max(4, side * 0.18))
                        .fill(.black.opacity(0.6))
                        .strokeBorder(.orange.opacity(0.4), lineWidth: 1.5)
                )
        }
    }
}

// MARK: - MouselessGridView

struct MouselessGridView: View {
    let columns: [String]
    let rows: [String]
    let selectedColumn: Int?
    var cornerRadius: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { rowIdx in
                    HStack(spacing: 6) {
                        ForEach(columns.indices, id: \.self) { colIdx in
                            let isSelected = selectedColumn == colIdx
                            let active = selectedColumn == nil || isSelected
                            let label = isSelected
                                ? rows[rowIdx].uppercased()
                                : "\(columns[colIdx].uppercased())\(rows[rowIdx].uppercased())"
                            MouselessCell(label: label, active: active)
                        }
                    }
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .ignoresSafeArea()
    }
}

// MARK: - MouselessCell

private struct MouselessCell: View {
    let label: String
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let scale: CGFloat = label.count == 1 ? 0.55 : 0.32
            let fontSize = max(14, side * scale)
            Text(label)
                .font(.system(size: fontSize, weight: .black, design: .monospaced))
                .tracking(label.count == 1 ? 0 : fontSize * 0.35)
                .foregroundStyle(.white.opacity(active ? 1.0 : 0.25))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: max(6, side * 0.15))
                        .fill(.orange.opacity(active ? 0.10 : 0.03))
                        .strokeBorder(.orange.opacity(active ? 0.25 : 0.05), lineWidth: 1.5)
                )
        }
    }
}
