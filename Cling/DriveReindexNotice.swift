import Lowtech
import SwiftUI
import System

// MARK: - Drive reindex offer

/// What searching a drive offers when its index may be missing changes only a walk would find. Nothing walks it for
/// this on its own: the drive may be huge and slow, and may not be searched again before its reindex interval walks it
/// anyway.
extension FuzzyClient {
    static func reindexNotice(_ drives: [FilePath]) -> String {
        drives.count == 1 ? "\(drives[0].name.string) may need a reindex" : "\(drives.count) drives may need a reindex"
    }

    /// One line per drive, with why.
    func reindexReasons(_ drives: [FilePath]) -> String {
        drives.compactMap { drive in volumesNeedingWalk[drive].map { "\(drive.name.string): \($0)" } }.joined(separator: "\n")
    }

    func reindexDrives(_ drives: [FilePath]) {
        indexVolumes(drives)
    }

    func skipDriveReindex(_ drives: [FilePath]) {
        for drive in drives {
            forgetWalkNeeded(drive)
        }
    }

    static let skipReindexHelp = "Keep the current index until the next scheduled reindex"
}

// MARK: - DriveReindexNotice

/// Under the results of a search narrowed to drives that may need a reindex.
struct DriveReindexNotice: View {
    let drives: [FilePath]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
            Text(FuzzyClient.reindexNotice(drives))
                .help(FUZZY.reindexReasons(drives))
            Button("Reindex") { FUZZY.reindexDrives(drives) }
                .foregroundStyle(Color.accentColor)
            Button("Skip") { FUZZY.skipDriveReindex(drives) }
                .help(FuzzyClient.skipReindexHelp)
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
