import KeyboardShortcuts
import SwiftUI

// MARK: - ShortcutsSettingsPane

struct ShortcutsSettingsPane: View {
    @State private var conflict: String?

    private let displaySegments: [ActionSegment] = [.open, .fileOps, .share, .destructive, .alternate]

    var body: some View {
        Form {
            ForEach(displaySegments, id: \.self) { segment in
                let items = ToolbarAction.rebindable.filter { $0.segment == segment }
                if !items.isEmpty {
                    Section(segment.title) {
                        ForEach(items) { action in
                            LabeledContent {
                                ShortcutRecorder(name: ClingShortcuts.name(for: action.id)) { _ in
                                    validate(action.id)
                                }
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                    }
                }
            }
            if let conflict {
                Section {
                    Text(conflict).foregroundStyle(.red).font(.callout)
                }
            }
            Section {
                Button("Reset all shortcuts to defaults") {
                    KeyboardShortcuts.reset(ClingShortcuts.allNames)
                    conflict = nil
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func validate(_ id: ActionID) {
        guard let new = KeyboardShortcuts.getShortcut(for: ClingShortcuts.name(for: id)),
              let owner = ClingShortcuts.duplicateOwner(of: new, excluding: id) else {
            conflict = nil; return
        }
        // Reject the duplicate: clear it and tell the user.
        KeyboardShortcuts.setShortcut(nil, for: ClingShortcuts.name(for: id))
        let a = ToolbarAction.byID[id]?.title ?? id.rawValue
        let b = ToolbarAction.byID[owner]?.title ?? owner.rawValue
        conflict = "\(a) conflicts with \(b). Shortcut cleared."
    }
}
