//
//  SearchBarSheets.swift
//  Cling
//
//  The sheets the bar can raise reuse the main window's SwiftUI views. A one-point hosting view in
//  the bar presents them, and it observes nothing but the pending request.
//

import Lowtech
import SwiftUI
import System

// MARK: - SearchBarSheets

@MainActor @Observable
final class SearchBarSheets {
    enum Request: Identifiable {
        case rename([FilePath])
        case copyTo([FilePath])
        case moveTo([FilePath])
        case editFilters
        case exclude([FilePath])
        /// ⌘S, with the draft in `quickDraft` or the `folder…` fields.
        case addQuickFilter
        case addFolderFilter

        var id: String {
            switch self {
            case let .rename(paths): "rename:\(paths.count)"
            case let .copyTo(paths): "copy:\(paths.count)"
            case let .moveTo(paths): "move:\(paths.count)"
            case .editFilters: "filters"
            case let .exclude(paths): "exclude:\(paths.count)"
            case .addQuickFilter: "addQuickFilter"
            case .addFolderFilter: "addFolderFilter"
            }
        }
    }

    static let shared = SearchBarSheets()

    var request: Request?
    var renameSubmission: RenameSubmission?

    var quickDraft = QuickFilterDraft()
    var folderID = ""
    var folderFolders: [FilePath] = []
    var folderKey: SauceKey = .escape

    /// Opens the editor ⌘S calls for, filled in from the query the way the window does it.
    func saveQueryAsFilter(_ query: String) {
        switch FilterDraftFromQuery(query: query) {
        case let .quick(draft):
            quickDraft = draft
            pendingDraft = .addQuickFilter
        case let .folder(id, folders, key):
            folderID = id
            folderFolders = folders
            folderKey = key
            pendingDraft = .addFolderFilter
        }
        request = pendingDraft
    }

    /// Called as any sheet closes: a filter draft is saved here, like the window's sheets do on dismiss.
    func finishFilterDrafts() {
        switch pendingDraft {
        case .addQuickFilter:
            finishQuickFilterDraft(quickDraft)
            quickDraft = QuickFilterDraft()
        case .addFolderFilter:
            finishFolderFilterDraft(id: folderID, folders: folderFolders, key: folderKey)
            folderID = ""; folderFolders = []; folderKey = .escape
        default:
            break
        }
        pendingDraft = nil
    }

    /// The filter editor that's open, so closing it saves the right draft.
    private var pendingDraft: Request?

}

// MARK: - SearchBarSheetHost

struct SearchBarSheetHost: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .sheet(item: $sheets.request, onDismiss: { sheets.finishFilterDrafts() }) { request in
                switch request {
                case let .rename(paths):
                    RenameView(originalPaths: paths, submission: $sheets.renameSubmission)
                case let .copyTo(paths):
                    FileOperationSheet(operation: .copy, files: paths)
                case let .moveTo(paths):
                    FileOperationSheet(operation: .move, files: paths) { moved in
                        SB.removeFromResults(moved)
                    }
                case .editFilters:
                    FilterEditorSheet()
                        .environmentObject(envState)
                case let .exclude(paths):
                    ExcludeFromIndexSheet(paths: paths)
                        .frame(width: 600, height: 540)
                case .addQuickFilter:
                    QuickFilterAddSheet(draft: $sheets.quickDraft)
                        .environmentObject(envState)
                case .addFolderFilter:
                    FolderFilterAddSheet(id: $sheets.folderID, folders: $sheets.folderFolders, key: $sheets.folderKey)
                        .environmentObject(envState)
                }
            }
            .onChange(of: sheets.renameSubmission) { _, submission in
                guard let submission else { return }
                sheets.renameSubmission = nil
                SB.applyRename(submission)
            }
    }

    @State private var sheets = SearchBarSheets.shared
}
