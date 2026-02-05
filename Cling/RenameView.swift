import Foundation
import Lowtech
import SwiftUI
import System

struct RenameView: View {
    init(originalPaths: [FilePath], renamedPaths: Binding<[FilePath]?>) {
        let sorted = originalPaths.sorted { $0.string < $1.string }
        self.originalPaths = sorted
        _renamedPaths = renamedPaths
        _text = State(initialValue: sorted.map(\.string).joined(separator: "\n"))
    }

    @Binding var renamedPaths: [FilePath]?
    @Environment(\.dismiss) var dismiss

    let originalPaths: [FilePath]

    var body: some View {
        VStack {
            if singleFile {
                TextField("Filename", text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(doRename)
            } else {
                ScrollView(.horizontal) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollContentBackground(.hidden)
                .roundbg(radius: 12, verticalPadding: 2, horizontalPadding: 2, color: .gray.opacity(0.1))
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .fixedSize()
                    Spacer()
                }
                Button("Rename", action: doRename)
                    .keyboardShortcut(.return, modifiers: singleFile ? [] : [.command])
            }
        }
        .padding()
        .frame(minWidth: singleFile ? nil : 900)
    }

    @State private var text: String
    @State private var errorMessage: String? = nil

    private var singleFile: Bool { originalPaths.count == 1 }

    private func doRename() {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.count != originalPaths.count {
            errorMessage = "File count mismatch: expected \(originalPaths.count) lines, got \(lines.count)."
        } else {
            renamedPaths = lines.map { FilePath($0) }
            errorMessage = nil
            dismiss()
        }
    }

}

func performRenameOperation(originalPaths: [FilePath], renamedPaths: [FilePath]) throws -> [FilePath: FilePath] {
    guard !renamedPaths.isEmpty, originalPaths.count == renamedPaths.count else {
        throw NSError(domain: "RenameError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mismatched file count."])
    }

    let onlyChanged = zip(originalPaths.sorted(by: \.string), renamedPaths).filter { $0.0 != $0.1 }
    guard !onlyChanged.isEmpty else {
        return [:]
    }

    // Single file: atomic rename via POSIX rename(2), fallback to move for cross-volume
    if onlyChanged.count == 1 {
        let (oldPath, newPath) = onlyChanged[0]
        let newDir = newPath.removingLastComponent()
        if !newDir.exists {
            try FileManager.default.createDirectory(at: newDir.url, withIntermediateDirectories: true)
        }
        if rename(oldPath.string, newPath.string) != 0 {
            if errno == EXDEV {
                try FileManager.default.moveItem(at: oldPath.url, to: newPath.url)
            } else {
                throw NSError(domain: "RenameError", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to rename: \(String(cString: strerror(errno)))",
                ])
            }
        }
        return [oldPath: newPath]
    }

    // Multi file: use temporary directory to avoid collisions
    let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: onlyChanged[0].0.url, create: true)
    guard let replacementDir = tempDir.filePath, replacementDir.mkdir(withIntermediateDirectories: true) else {
        throw NSError(domain: "RenameError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create temporary directory."])
    }

    let tempMapping = onlyChanged.dict { (UUID().uuidString, $0) }
    for (tempName, (originalFile, _)) in tempMapping {
        try originalFile.move(to: replacementDir / tempName)
    }

    for (tempName, (_, newFile)) in tempMapping {
        try (replacementDir / tempName).move(to: newFile)
    }
    return Dictionary(uniqueKeysWithValues: onlyChanged)
}
