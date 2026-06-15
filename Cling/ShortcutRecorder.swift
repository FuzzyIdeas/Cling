import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - ShortcutRecorder

/// Drop-in replacement for `KeyboardShortcuts.Recorder` that makes any click inside the field
/// reliably enter recording mode. Use this instead of the package's `Recorder` everywhere.
struct ShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil

    func makeNSView(context: Context) -> ClickToRecordRecorder {
        ClickToRecordRecorder(for: name, onChange: onChange)
    }

    func updateNSView(_ nsView: ClickToRecordRecorder, context: Context) {
        nsView.recorder.shortcutName = name
    }

    // Without this, SwiftUI's default representable sizing treats the wrapper (a plain
    // NSView with `defaultLow` hugging priorities) as freely stretchable and expands it
    // to the full proposed row height: in a grouped Form row the label gets top-aligned
    // with dead space below it while the recorder fills the rest. Reporting the
    // recorder's own fixed size makes the row hug the field and center it vertically
    // like any other control.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClickToRecordRecorder, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - ClickToRecordRecorder

/// Hosts a `KeyboardShortcuts.RecorderCocoa` and takes over its mouse handling.
///
/// Why: the package starts recording ONLY inside `RecorderCocoa.becomeFirstResponder()`
/// (RecorderCocoa.swift:206), which installs the `LocalEventMonitor` that captures the combo and
/// hides the caret via `hideCaret()` -> `currentEditor()?.insertionPointColor = .clear`
/// (Utilities.swift:28). On macOS 26, clicking the field can leave it looking and behaving like
/// a plain editable text field instead: the field editor activates with a visible caret and
/// mouse-selectable text (`currentEditor()` is not installed yet when `becomeFirstResponder()`
/// runs, so `hideCaret()` no-ops), and once the field editor is first responder a later click
/// never re-enters `becomeFirstResponder()`, so a recorder whose monitor died (e.g. after a
/// conflict alert blurred it) cannot be reactivated by clicking the text area; only the cancel
/// (x) button worked because `controlTextDidChange` calls `focus()`.
///
/// The fix: swallow every click except on the cancel button (via `hitTest`) and drive the
/// package's own activation path explicitly (`makeFirstResponder`), forcing a clean
/// resign-then-focus when a stale editing session is active. Caret hiding and text deselection
/// are re-applied on the next runloop tick (when the field editor is guaranteed to exist) every
/// time any recorder activates, keyboard-focused ones included.
@MainActor
final class ClickToRecordRecorder: NSView {
    init(for name: KeyboardShortcuts.Name, onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil) {
        recorder = KeyboardShortcuts.RecorderCocoa(for: name, onChange: onChange)
        super.init(frame: .zero)

        recorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recorder)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            recorder.topAnchor.constraint(equalTo: topAnchor),
            recorder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The package posts this (internal symbol, reconstructed from its raw string) from
        // `becomeFirstResponder()`/`endRecording()`. Re-apply the recording cosmetics whenever
        // OUR recorder becomes active, regardless of how it was activated (click, tab focus,
        // or the package's own `focus()` after a conflict alert).
        recorderActiveObserver = NotificationCenter.default.addObserver(
            forName: Self.recorderActiveStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.userInfo?["isActive"] as? Bool == true else { return }
            DispatchQueue.main.async {
                self.applyRecordingCosmetics()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let recorderActiveObserver {
            NotificationCenter.default.removeObserver(recorderActiveObserver)
        }
    }

    override var intrinsicContentSize: NSSize { recorder.intrinsicContentSize }

    let recorder: KeyboardShortcuts.RecorderCocoa

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }

        // Let the cancel (x) button keep its normal behavior (clears the shortcut). The cell
        // only carries a cancelButtonCell while the field has text (the package nils it
        // otherwise), so an empty field can't accidentally forward edge clicks.
        let pointInRecorder = recorder.convert(point, from: superview)
        if let cell = recorder.cell as? NSSearchFieldCell, cell.cancelButtonCell != nil,
           cell.cancelButtonRect(forBounds: recorder.bounds).contains(pointInRecorder)
        {
            return hit
        }

        // Swallow every other click so the field editor never starts a mouse-driven
        // text-editing session; `mouseDown` below enters recording instead.
        return self
    }

    override func mouseDown(with _: NSEvent) {
        startRecording()
    }

    private static let recorderActiveStatusDidChange = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    private var recorderActiveObserver: NSObjectProtocol?

    private func startRecording() {
        guard let window = recorder.window else { return }

        // If the field editor is already active (a previous click or a stale recording session
        // left the field in text-editing state), `makeFirstResponder(recorder)` would be a
        // no-op and recording would never (re)start: resign first, then re-enter on the next
        // tick so AppKit finishes tearing down the editing session.
        if let editor = recorder.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in
                self?.focusRecorder()
            }
        } else {
            focusRecorder()
        }
    }

    private func focusRecorder() {
        recorder.window?.makeFirstResponder(recorder)
    }

    /// Defensive re-application of what `RecorderCocoa.becomeFirstResponder()` intends:
    /// hidden caret and no text selection. Runs one tick after activation, when the field
    /// editor is guaranteed to be installed (the package's `hideCaret()` can run before that
    /// on macOS 26 and silently no-op). Guarded by `currentEditor()`: only the recorder that
    /// is actually recording has one.
    private func applyRecordingCosmetics() {
        guard let editor = recorder.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = .clear
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }
}
