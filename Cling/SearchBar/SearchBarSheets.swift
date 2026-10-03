//
//  SearchBarSheets.swift
//  Cling
//
//  The sheets the bar can raise reuse the main window's SwiftUI views. A one-point hosting view in
//  the bar presents them, and it observes nothing but the pending request.
//

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

        var id: String {
            switch self {
            case let .rename(paths): "rename:\(paths.count)"
            case let .copyTo(paths): "copy:\(paths.count)"
            case let .moveTo(paths): "move:\(paths.count)"
            case .editFilters: "filters"
            }
        }
    }

    static let shared = SearchBarSheets()

    var request: Request?
    var renameSubmission: RenameSubmission?
}

// MARK: - SearchBarSheetHost

struct SearchBarSheetHost: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .sheet(item: $sheets.request) { request in
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
