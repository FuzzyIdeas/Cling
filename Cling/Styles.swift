//
//  Styles.swift
//  Cling
//
//  Created by Alin Panaitiu on 06.02.2025.
//

import Foundation
import Lowtech
import SwiftUI

/// One radius shared by the results table, the file preview panel and the action-row background so
/// their rounded corners read as nested inside the window. macOS doesn't expose the window's own
/// radius, and these panels sit only ~16pt in from the edge, so a true concentric inset (via
/// `ContainerRelativeShape`) would round to almost square; a single tuned value tracks the window
/// far better here. Tune this one number to taste.
let windowCornerRadius: CGFloat = 16

// MARK: - TextButtonContent

/// The rendered body shared by the text button styles. This is a real `View` (not the ButtonStyle
/// struct), so its `@State hovering` is actually installed and tracked by SwiftUI. The styles used
/// to call each other's `makeBody` by hand, which left that `@State` dead — the hover and press
/// feedback never updated. Hover/press now drive both the background fill and a subtle scale.
private struct TextButtonContent<Label: View>: View {
    enum Variant { case glass, vibrant, opaque }

    let label: Label
    let isPressed: Bool
    let variant: Variant
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    var body: some View {
        label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .contentShape(isSquare ? AnyShape(squareShape) : AnyShape(Capsule(style: .continuous)))
            .opacity(enabled ? (hovering ? 1 : 0.82) : 0.5)
            .background { fillBackground }
            .overlay { border }
            .scaleEffect(enabled && hovering ? 1.06 : 1)
            .onHover { hover in
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.14)) { hovering = hover }
            }
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var enabled: Bool {
        isEnabledOverride ?? isEnabled
    }

    /// Opaque pills are squarish (small radius); glass/vibrant are capsules.
    private var isSquare: Bool {
        variant == .opaque
    }
    private var squareShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
    }

    private var fillColor: Color {
        if active { return activeTint.opacity(0.22) }

        if variant == .glass {
            // A contrasting fill against the translucent window: whiter in light, blacker in dark,
            // getting more opaque on hover/press.
            let base = scheme == .dark ? Color.black : Color.white
            guard enabled else { return base.opacity(scheme == .dark ? 0.12 : 0.22) }
            if isPressed { return base.opacity(scheme == .dark ? 0.5 : 0.72) }
            if hovering { return base.opacity(scheme == .dark ? 0.4 : 0.6) }
            return base.opacity(scheme == .dark ? 0.28 : 0.45)
        }

        // Bordered variants rely on their stroke at rest, filling in only on hover/press.
        guard enabled else { return .clear }
        if isPressed { return .primary.opacity(0.18) }
        if hovering { return .primary.opacity(0.12) }
        return .clear
    }

    @ViewBuilder
    private var fillBackground: some View {
        if isSquare {
            squareShape.fill(fillColor)
        } else {
            Capsule(style: .continuous).fill(fillColor)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch variant {
        case .glass:
            // A caller that opts out (e.g. the status bar passes `.clear`) wins; otherwise the glass
            // pills get a modern top-lit bevel edge that reads as a thin glass rim.
            if let borderColor {
                Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.5)
            } else {
                Capsule(style: .continuous).strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(scheme == .dark ? 0.30 : 0.65),
                            .black.opacity(scheme == .dark ? 0.04 : 0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
        case .vibrant:
            Capsule(style: .continuous).strokeBorder(borderColor ?? color, lineWidth: 0.5)
        case .opaque:
            squareShape.strokeBorder((borderColor ?? color).opacity(0.4), lineWidth: 1)
        }
    }

}

// MARK: - GlassTextButton

struct GlassTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .glass, color: color, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - VibrantTextButton

struct VibrantTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .vibrant, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - OpaqueTextButton

struct OpaqueTextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor
    var isEnabledOverride: Bool?

    func makeBody(configuration: Configuration) -> some View {
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: .opaque, color: color, borderColor: borderColor, active: active, activeTint: activeTint, isEnabledOverride: isEnabledOverride)
    }

}

// MARK: - TextButton

struct TextButton: ButtonStyle {
    var color = Color.primary.opacity(0.8)
    var borderColor: Color?
    var active = false
    var activeTint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let variant: TextButtonContent<Configuration.Label>.Variant = AM.useGlass ? .glass : (AM.useVibrant ? .vibrant : .opaque)
        TextButtonContent(label: configuration.label, isPressed: configuration.isPressed, variant: variant, color: color, borderColor: borderColor, active: active, activeTint: activeTint)
    }

}

extension ButtonStyle where Self == TextButton {
    static var text: TextButton {
        TextButton()
    }
    static func text(color: Color = .primary.opacity(0.8), borderColor: Color? = nil, active: Bool = false, activeTint: Color = .accentColor) -> TextButton {
        TextButton(color: color, borderColor: borderColor, active: active, activeTint: activeTint)
    }
}

extension ButtonStyle where Self == GlassTextButton {
    static var glassText: GlassTextButton {
        GlassTextButton()
    }
}

extension ButtonStyle where Self == VibrantTextButton {
    static var vibrantText: VibrantTextButton {
        VibrantTextButton()
    }
}

extension ButtonStyle where Self == OpaqueTextButton {
    static var opaqueText: OpaqueTextButton {
        OpaqueTextButton()
    }
}

extension ButtonStyle where Self == BorderlessTextButton {
    static var borderlessText: BorderlessTextButton {
        BorderlessTextButton()
    }
    static func borderlessText(color: Color) -> BorderlessTextButton {
        BorderlessTextButton(color: color)
    }
}

// MARK: - BorderlessTextButton

struct BorderlessTextButton: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    var color = Color.primary.opacity(0.8)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 4.0)
            .contentShape(Rectangle())
            .onHover { hover in
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) { hovering = hover }
            }
            .opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.6)
    }

    @State private var hovering = false

}

// MARK: - ButtonFlash

/// Transient confirmation message ("Copied", "Link copied", …) that overlays a button.
/// Fills the button's footprint so it shares the button's width and capsule radius; longer
/// text scales down to fit rather than spilling past the button.
struct ButtonFlash: ViewModifier {
    let text: String
    let visible: Bool
    var fontSize: CGFloat = 10
    var tint: Color = .accentColor

    func body(content: Content) -> some View {
        content.overlay {
            if visible {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint, in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

extension View {
    func buttonFlash(_ text: String, visible: Bool, fontSize: CGFloat = 10, tint: Color = .accentColor) -> some View {
        modifier(ButtonFlash(text: text, visible: visible, fontSize: fontSize, tint: tint))
    }
}

extension View {
    func transparentTableBackground() -> some View {
        onAppear {
            // Remove opaque backgrounds from NSTableView header and enclosing scroll view
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for tableView in window.contentView?.findViews(ofType: NSTableView.self) ?? [] {
                        tableView.backgroundColor = .clear
                        tableView.enclosingScrollView?.backgroundColor = .clear
                        tableView.enclosingScrollView?.drawsBackground = false
                        tableView.headerView?.wantsLayer = true
                        tableView.headerView?.layer?.backgroundColor = .clear
                        if let headerClip = tableView.headerView?.superview {
                            headerClip.wantsLayer = true
                            headerClip.layer?.backgroundColor = .clear
                        }
                        // Clear the corner view (top-right square)
                        tableView.enclosingScrollView?.wantsLayer = true
                        if let cornerView = tableView.cornerView {
                            cornerView.wantsLayer = true
                            cornerView.layer?.backgroundColor = .clear
                        }
                    }
                }
            }
        }
    }

    func raisedPanel(cornerRadius: CGFloat = windowCornerRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.background.opacity(0.4))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    func glassOrMaterial(cornerRadius: CGFloat = 18) -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Full-width translucent bar for floating over preview content: Liquid
    /// Glass on macOS 26 (when enabled), ultra-thin material otherwise. The
    /// image or text underneath shows through it. Outer corners are left square
    /// and clipped to shape by the enclosing panel.
    @ViewBuilder
    func glassBar() -> some View {
        if AM.useGlass, #available(macOS 26, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.ultraThinMaterial)
        }
    }

    /// Adds a double click handler this view (macOS only)
    ///
    /// Example
    /// ```
    /// Text("Hello")
    ///     .onDoubleClick { print("Double click detected") }
    /// ```
    /// - Parameters:
    ///   - handler: Block invoked when a double click is detected
    func onDoubleClick(handler: @escaping () -> Void) -> some View {
        modifier(DoubleClickHandler(handler: handler))
    }
}

extension NSView {
    func findViews<T: NSView>(ofType type: T.Type) -> [T] {
        var found = [T]()
        for sub in subviews {
            if let match = sub as? T { found.append(match) }
            found.append(contentsOf: sub.findViews(ofType: type))
        }
        return found
    }
}

extension View {
    /// SwiftUI's `Table` leaves the backing `NSTableView` on automatic row heights,
    /// which forces an Auto Layout measuring pass over EVERY inserted row when the
    /// data changes in bulk (a fresh search replacing the whole result set). Each
    /// measured row instantiates its cells, and those read `path.memoz.size/.date/.icon`
    /// — synchronous `stat` + icon fetches for local files — so a search returning
    /// thousands of rows ran thousands of disk calls on the main thread inside one
    /// `endUpdates`, freezing the app for 30s+ (CLING-B). The rows here are uniform
    /// single-line cells, so we pin a fixed row height and turn automatic heights off:
    /// `NSTableView` then derives the total content height as `rowCount × rowHeight`
    /// without measuring off-screen rows, and only ever instantiates cells (and touches
    /// `memoz`) for the handful that are actually visible.
    func fixedTableRowHeight(_ height: CGFloat) -> some View {
        background(TableRowHeightConfigurator(rowHeight: height))
    }
}

// MARK: - TableScrollSync

/// Mirrors horizontal scrolling between the pinned stash table and the results table so their
/// columns stay visually aligned, and configures the stash table's scrollers and exact height.
@MainActor
final class TableScrollSync {
    static let shared = TableScrollSync()

    /// While the whole stash fits (no internal scrolling), keep it pinned to the top so trackpad
    /// pans can't wiggle the rows into the document's bottom padding.
    var stashVerticalLock = false

    /// The table document's bottom padding below the last row. Only measurable while the document
    /// view is NOT stretched to fill the clip (otherwise the stretch leaks into the value), so it
    /// gets cached from the first unstretched layout pass.
    var stashBottomPad: CGFloat?

    func register(_ scrollView: NSScrollView, isStash: Bool) {
        if isStash { stashScrollView = scrollView } else { resultsScrollView = scrollView }
        // Keyed by the clip view, not the scroll view: the stash swaps its clip view for the
        // locking subclass, and the observer must follow to the new object.
        let id = ObjectIdentifier(scrollView.contentView)
        guard !observed.contains(id) else { return }
        observed.insert(id)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak scrollView] _ in
            guard let scrollView else { return }
            MainActor.assumeIsolated { TableScrollSync.shared.boundsChanged(in: scrollView) }
        }
    }

    private weak var stashScrollView: NSScrollView?
    private weak var resultsScrollView: NSScrollView?
    private var observed = Set<ObjectIdentifier>()
    private var syncing = false

    private func boundsChanged(in source: NSScrollView) {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        // Pin the locked stash to its top edge (origin sits at -inset when scrolled to top).
        if source === stashScrollView, stashVerticalLock {
            let top = -source.contentView.contentInsets.top
            if abs(source.contentView.bounds.origin.y - top) > 0.5 {
                source.contentView.bounds.origin.y = top
                source.reflectScrolledClipView(source.contentView)
            }
        }

        // Mirror horizontal scrolling to the other table.
        let target = source === stashScrollView ? resultsScrollView : stashScrollView
        guard let target, target !== source else { return }
        let x = source.contentView.bounds.origin.x
        guard abs(target.contentView.bounds.origin.x - x) > 0.5 else { return }
        target.contentView.bounds.origin.x = x
        target.reflectScrolledClipView(target.contentView)
    }
}

extension View {
    /// Registers the table for mirrored horizontal scrolling. With `isStash: true` it also hides
    /// the horizontal scrollbar, disables vertical scrolling while every row fits (`lockVertical`)
    /// and reports into `fittingHeight` the exact height showing `visibleRows` rows + header,
    /// derived from the live layout so intercell spacing and header height are always right.
    func syncedTableScroll(
        isStash: Bool,
        lockVertical: Bool = false,
        visibleRows: Int = 0,
        fittingHeight: Binding<CGFloat>? = nil
    ) -> some View {
        background(TableScrollConfigurator(
            isStash: isStash, lockVertical: lockVertical,
            visibleRows: visibleRows, fittingHeight: fittingHeight
        ))
    }
}

// MARK: - TableScrollConfigurator

private struct TableScrollConfigurator: NSViewRepresentable {
    let isStash: Bool
    let lockVertical: Bool
    let visibleRows: Int
    let fittingHeight: Binding<CGFloat>?

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            // The background view spans exactly the frame of the Table it's attached to, so the
            // right scroll view is the one containing its center (in window coordinates). A
            // superview walk can't be trusted here: SwiftUI hosts backgrounds outside the table's
            // subtree, so both tables' walks escalate to the shared container and find the SAME
            // (first) table — which broke mirroring and applied the stash lock to the wrong table.
            guard let window = view.window, let contentView = window.contentView else { return }
            let probe = view.convert(view.bounds, to: nil)
            guard probe.width > 0, probe.height > 0 else { return }
            let center = NSPoint(x: probe.midX, y: probe.midY)
            let scrollView = contentView.findViews(ofType: NSTableView.self)
                .compactMap(\.enclosingScrollView)
                .first { $0.convert($0.bounds, to: nil).contains(center) }
            guard let scrollView else { return }
            // Hard-block vertical scrolling while everything fits: swap in a clip view whose
            // constrainBoundsRect clamps the vertical origin, so pans, momentum and bounces can't
            // move the rows at all (the reactive pin below only snaps back after the fact).
            // Only when the table uses a plain NSClipView; never discard a custom subclass.
            if isStash, type(of: scrollView.contentView) == NSClipView.self, let doc = scrollView.documentView {
                let old = scrollView.contentView
                let clip = LockableClipView()
                clip.automaticallyAdjustsContentInsets = old.automaticallyAdjustsContentInsets
                clip.contentInsets = old.contentInsets
                clip.drawsBackground = old.drawsBackground
                clip.backgroundColor = old.backgroundColor
                scrollView.contentView = clip
                scrollView.documentView = doc
            }
            TableScrollSync.shared.register(scrollView, isStash: isStash)
            guard isStash else { return }

            (scrollView.contentView as? LockableClipView)?.lockScrolling = lockVertical
            TableScrollSync.shared.stashVerticalLock = lockVertical
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.hasVerticalScroller = !lockVertical
            scrollView.verticalScrollElasticity = lockVertical ? .none : .automatic

            if let fittingHeight, let table = scrollView.documentView as? NSTableView, table.numberOfRows > 0 {
                // Exact fit = the floating header's inset on the clip view + the bottom edge of
                // the last visible row + the document's own bottom padding. Row rects are immune
                // to the document-view stretching that made frame-based math either overshoot
                // (never shrink) or undershoot (clip rows).
                let insetTop = scrollView.contentView.contentInsets.top
                let clipDocArea = scrollView.contentView.bounds.height - insetTop
                let lastRowBottom = table.rect(ofRow: table.numberOfRows - 1).maxY
                if table.frame.height > clipDocArea + 0.5 {
                    TableScrollSync.shared.stashBottomPad = max(0, table.frame.height - lastRowBottom)
                }
                let pad = TableScrollSync.shared.stashBottomPad ?? max(0, table.rect(ofRow: 0).minY) * 2
                let rows = min(max(visibleRows, 1), table.numberOfRows)
                let height = insetTop + table.rect(ofRow: rows - 1).maxY + pad
                if height > 0, abs(fittingHeight.wrappedValue - height) > 0.5 {
                    fittingHeight.wrappedValue = height
                }
            }
        }
    }
}

// MARK: - LockableClipView

/// Clip view that refuses user scrolling entirely while `lockScrolling` is set: the stash table
/// shows all its rows, so pans/momentum/bounces would only jiggle the pinned rows. User scrolls
/// come through `scroll(to:)` and hit this clamp; the horizontal mirroring from the results table
/// mutates the bounds origin directly, bypassing it, so column alignment still follows.
private final class LockableClipView: NSClipView {
    var lockScrolling = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if lockScrolling {
            rect.origin.y = -contentInsets.top
            rect.origin.x = bounds.origin.x
        }
        return rect
    }
}

// MARK: - TableRowHeightConfigurator

private struct TableRowHeightConfigurator: NSViewRepresentable {
    let rowHeight: CGFloat

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        apply(from: nsView)
    }

    /// The table may not be in the window hierarchy yet on the first pass, so run on
    /// the next tick and re-run on every SwiftUI update (which fires when results
    /// change, covering a table that gets rebuilt). Scoped to this view's own window
    /// so it never touches tables in other windows (e.g. Settings).
    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            guard let contentView = view.window?.contentView else { return }
            for table in contentView.findViews(ofType: NSTableView.self) {
                guard table.usesAutomaticRowHeights || table.rowHeight != rowHeight else { continue }
                table.usesAutomaticRowHeights = false
                table.rowHeight = rowHeight
            }
        }
    }
}

// MARK: - DoubleClickHandler

struct DoubleClickHandler: ViewModifier {
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickListeningViewRepresentable(handler: handler)
        }
    }
}

// MARK: - DoubleClickListeningViewRepresentable

struct DoubleClickListeningViewRepresentable: NSViewRepresentable {
    let handler: () -> Void

    func makeNSView(context: Context) -> DoubleClickListeningView {
        DoubleClickListeningView(handler: handler)
    }
    func updateNSView(_ nsView: DoubleClickListeningView, context: Context) {}
}

// MARK: - DoubleClickListeningView

class DoubleClickListeningView: NSView {
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    let handler: () -> Void

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            handler()
        }
    }
}
