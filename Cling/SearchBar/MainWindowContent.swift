//
//  MainWindowContent.swift
//  Cling
//

import SwiftUI

/// The search window's content, or nothing while it is suspended for the search bar.
///
/// A hidden or closed `Window` scene keeps its view graph, and ContentView observes the same
/// results the bar shows, so without this every keystroke in the bar also rebuilt the hidden
/// window's table: measured on an M1 Max, that was most of the bar's main thread time. Dropping the
/// content tears the graph down; it is built again the next time the window is summoned.
struct MainWindowContent: View {
    var body: some View {
        if wm.mainContentSuspended {
            Color.clear
        } else {
            ContentView()
        }
    }

    @State private var wm = WM
}
