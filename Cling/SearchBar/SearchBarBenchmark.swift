//
//  SearchBarBenchmark.swift
//  Cling
//
//  In-process benchmark for the search bar, for Macs nobody is sitting at. Launch with
//  `-searchBarBenchmark [-searchBarBenchmarkOut <path>]` and it waits for the index, opens the bar,
//  types, arrows through results, swaps result sets and idles under file churn, in every window
//  style, with and without the preview, then writes a report and quits.
//
//  Measured per scenario:
//  - main thread busy time per run loop iteration, from wake-up to just before sleeping again, so
//    it includes layout, drawing and the Core Animation commit (the observer runs after CA's);
//  - iterations over one 120 Hz and one 60 Hz frame;
//  - frames the display link saw arrive late;
//  - main thread and whole process CPU time;
//  - for typing, the time from the keystroke to its results being on screen.
//
//  Only compiled into Debug builds and builds made with SEARCHBAR_BENCH.
//

#if DEBUG || SEARCHBAR_BENCH

    import AppKit
    import Defaults
    import Lowtech
    import OSLog
    import QuartzCore
    import SwiftUI
    import System

    private let signposter = OSSignposter(subsystem: clingSubsystem, category: "SearchBarBenchmark")

    // MARK: - SearchBarBenchmark

    @MainActor
    enum SearchBarBenchmark {
        // MARK: Meter

        /// Collects main thread iterations, late frames and CPU between `init` and `finish`.
        @MainActor
        final class Meter: NSObject {
            init(_ name: String, _ tag: String) {
                self.name = name
                self.tag = tag
                startTime = CACurrentMediaTime()
                startProcessCPU = Meter.processCPU()
                startMainCPU = Meter.mainThreadCPU()
                super.init()
                SearchBarBenchmark.counters = [:]
                SearchBarBenchmark.recording = true

                observer = CFRunLoopObserverCreateWithHandler(
                    kCFAllocatorDefault,
                    CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                    true, CFIndex.max
                ) { [weak self] _, activity in
                    let now = CACurrentMediaTime()
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if activity == .afterWaiting {
                            self.iterationStart = now
                        } else if self.iterationStart > 0 {
                            self.iterations.append((now - self.iterationStart) * 1000)
                            self.iterationStart = 0
                        }
                    }
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

                if let view = SB.root ?? NSApp.windows.first?.contentView {
                    let link = view.displayLink(target: self, selector: #selector(frame(_:)))
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                }
            }

            static func processCPUTime() -> Double {
                processCPU()
            }

            func finish(extra: String = "") {
                let duration = CACurrentMediaTime() - startTime
                SearchBarBenchmark.recording = false
                if let observer {
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                }
                displayLink?.invalidate()

                let processCPU = Meter.processCPU() - startProcessCPU
                let mainCPU = Meter.mainThreadCPU() - startMainCPU
                let busy = iterations.reduce(0, +)
                let over8 = iterations.filter { $0 > 8.3 }.count
                let over16 = iterations.filter { $0 > 16.7 }.count
                let sorted = iterations.sorted()
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                let maxIteration = sorted.last ?? 0
                let counters = SearchBarBenchmark.counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")

                SearchBarBenchmark.log(String(
                    format: "%@ [%@] %.1fs | main busy %.0fms (%.1f%%), p95 iter %.2fms, max %.1fms, >8.3ms %d, >16.7ms %d | late frames %d/%d | CPU main %.0fms (%.1f%%), process %.0fms (%.1f%%) | %@ %@",
                    name, tag, duration, busy, busy / (duration * 10), p95, maxIteration, over8, over16,
                    lateFrames, frames, mainCPU * 1000, mainCPU * 100 / duration, processCPU * 1000, processCPU * 100 / duration,
                    counters, extra
                ))
            }

            @objc func frame(_ link: CADisplayLink) {
                frames += 1
                if lastFrame > 0 {
                    let interval = link.timestamp - lastFrame
                    if interval > link.duration * 1.5 {
                        lateFrames += 1
                    }
                }
                lastFrame = link.timestamp
            }

            private let name: String
            private let tag: String
            private let startTime: CFTimeInterval
            private let startProcessCPU: Double
            private let startMainCPU: Double
            private var observer: CFRunLoopObserver?
            private var displayLink: CADisplayLink?
            private var iterationStart: CFTimeInterval = 0
            private var iterations: [Double] = []
            private var frames = 0
            private var lateFrames = 0
            private var lastFrame: CFTimeInterval = 0

            private static func processCPU() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                    + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            }

            /// Called on the main thread, so `mach_thread_self` is the main thread.
            private static func mainThreadCPU() -> Double {
                let thread = mach_thread_self()
                defer { mach_port_deallocate(mach_task_self_, thread) }
                var info = thread_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                    }
                }
                guard result == KERN_SUCCESS else { return 0 }
                return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
                    + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
            }
        }

        static let requested = CommandLine.arguments.contains("-searchBarBenchmark")

        static var recording = false
        static var counters: [String: Int] = [:]

        static func mark(_ name: StaticString) {
            signposter.emitEvent(name)
            guard recording else { return }
            counters["\(name)", default: 0] += 1
        }

        static func count(_ name: String) {
            guard recording else { return }
            counters[name, default: 0] += 1
        }

        static func startIfRequested() {
            if let query = argument("-searchBarShowcase") {
                Task { @MainActor in
                    await showcase(query)
                }
                return
            }
            guard requested else { return }
            Task { @MainActor in
                await run()
            }
        }

        static func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "p50 %.1fms p95 %.1fms max %.1fms", p50, p95, sorted.last!)
        }

        // MARK: Scenarios

        private static var lines: [String] = []
        private static let outPath = CommandLine.arguments.firstIndex(of: "-searchBarBenchmarkOut")
            .flatMap { CommandLine.arguments[safe: $0 + 1] } ?? "/private/tmp/cling-searchbar-bench.txt"

        /// Opens the bar on `query` with the second result selected and leaves it on screen, for screenshots of the real
        /// window, since offscreen renders lose the glass and blur. Theme and preview come from launch arguments
        /// (`-windowAppearance Vibrant -searchBarShowPreview '<false/>'`), and `-searchBarShowcaseDark` shows it dark.
        private static var showcaseWindow: NSWindow?

        /// Appends as it goes, so a run that dies half way still leaves what it measured.
        private static func log(_ line: String) {
            lines.append(line)
            print(line)
            if let handle = FileHandle(forWritingAtPath: outPath) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }

        private static func run() async {
            FileManager.default.createFile(atPath: outPath, contents: nil)
            log("# Cling search bar benchmark")
            log("host: \(Host.current().localizedName ?? "?"), \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) cores")
            if let screen = NSScreen.main {
                log("display: \(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x, \(screen.maximumFramesPerSecond) Hz")
            }

            // Wait for the index.
            let readyBy = Date().addingTimeInterval(240)
            while Date() < readyBy, FUZZY.indexedCount == 0 || FUZZY.indexing || !FUZZY.hasFullDiskAccess {
                try? await Task.sleep(for: .milliseconds(250))
            }
            log("index: \(FUZZY.indexedCount) files, FDA \(FUZZY.hasFullDiskAccess), ready after \(Int(Date().timeIntervalSince(readyBy.addingTimeInterval(-240))))s")
            try? await Task.sleep(for: .seconds(2))

            // After launch the index catches up on changes in the background for a while, which
            // would land in whichever scenario runs then.
            let quiet = await waitForQuiet()
            log("background quiet after \(quiet)s")

            let savedAppearance = Defaults[.windowAppearance]
            let savedPreview = Defaults[.searchBarShowPreview]
            let savedPinned = Defaults[.searchBarPinned]
            let savedQuery = FUZZY.query

            var appearances: [WindowAppearance] = [.vibrant, .opaque]
            if #available(macOS 26, *) {
                appearances.insert(.glassy, at: 0)
            }
            if let themes = argument("-searchBarBenchmarkThemes") {
                let wanted = Set(themes.lowercased().split(separator: ",").map(String.init))
                appearances = appearances.filter { wanted.contains($0.rawValue.lowercased()) }
            }
            let previews: [Bool] = switch argument("-searchBarBenchmarkPreview") {
            case "on": [true]
            case "off": [false]
            default: [false, true]
            }
            let only = argument("-searchBarBenchmarkScenarios").map { Set($0.split(separator: ",").map(String.init)) }
            func wants(_ name: String) -> Bool {
                only?.contains(name) ?? true
            }

            if let snapshotPrefix = argument("-searchBarSnapshot") {
                await snapshots(prefix: snapshotPrefix)
            }

            if wants("idle-baseline") {
                // The bar never opened, nothing pinned: what the churn costs Cling without the bar.
                Defaults[.searchBarPinned] = false
                SB.collapse()
                await settle(500)
                let meter = Meter("idle-baseline+churn", "hidden")
                await churn(seconds: 6)
                meter.finish()
            }

            for appearance in appearances {
                Defaults[.windowAppearance] = appearance
                AM.update()
                try? await Task.sleep(for: .milliseconds(300))
                for preview in previews {
                    Defaults[.searchBarShowPreview] = preview
                    try? await Task.sleep(for: .milliseconds(100))
                    // The churn of the previous idle scenarios leaves the index rescanning folders.
                    _ = await waitForQuiet()
                    let tag = "\(appearance.rawValue.lowercased())\(preview ? "+preview" : "")"
                    log("")
                    log("## \(tag)")
                    if wants("expand") {
                        await expandCollapse(tag)
                    }
                    if wants("type-wait") {
                        await typeAndWait(tag)
                    }
                    if wants("type-burst") {
                        await typeBurst(tag)
                    }
                    if wants("arrows") {
                        await arrows(tag)
                    }
                    if wants("list-updates") {
                        await listUpdates(tag)
                    }
                    if wants("list-inserts") {
                        await listInserts(tag)
                    }
                }
                if wants("idle-expanded") {
                    await idleExpanded(appearance.rawValue.lowercased())
                }
                if wants("idle-compact") {
                    await idleCompact(appearance.rawValue.lowercased())
                }
            }

            SB.collapse()
            Defaults[.windowAppearance] = savedAppearance
            Defaults[.searchBarShowPreview] = savedPreview
            Defaults[.searchBarPinned] = savedPinned
            AM.update()
            FUZZY.suppressNextSearch = true
            FUZZY.query = savedQuery

            log("# done")
            if CommandLine.arguments.contains("-searchBarBenchmarkQuit") {
                NSApp.terminate(nil)
            }
        }

        private static func ensureExpanded() async {
            if !SB.isExpanded {
                SB.expand()
            }
            await settle()
        }

        private static func setQuery(_ text: String) async {
            await ensureExpanded()
            SB.setQuery(text)
            await waitForResults(text)
            await settle()
        }

        /// Waits until the bar shows the results for `query`.
        private static func waitForResults(_ query: String, timeout: TimeInterval = 5) async {
            let deadline = CACurrentMediaTime() + timeout
            while CACurrentMediaTime() < deadline {
                if let state = SB.benchmarkState, state.query == query, !state.searching, !FUZZY.searching {
                    // One more turn so the update is committed and drawn.
                    await nextTurn()
                    return
                }
                await nextTurn()
            }
        }

        private static func settle(_ ms: Int = 250) async {
            try? await Task.sleep(for: .milliseconds(ms))
        }

        private static func nextTurn() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        private static func typeCharacter(_ ch: Character) {
            guard let root = SB.root else { return }
            if root.field.currentEditor() == nil {
                SB.panel?.makeFirstResponder(root.field)
            }
            if let editor = root.field.currentEditor() as? NSTextView {
                editor.insertText(String(ch), replacementRange: editor.selectedRange())
            } else {
                root.field.stringValue += String(ch)
                SB.queryEdited(root.field.stringValue)
            }
        }

        private static func expandCollapse(_ tag: String) async {
            await setQuery("")
            SB.collapse()
            await settle()
            let meter = Meter("expand", tag)
            var latencies: [Double] = []
            for _ in 0 ..< 10 {
                let start = CACurrentMediaTime()
                SB.expand()
                await nextTurn()
                latencies.append((CACurrentMediaTime() - start) * 1000)
                await settle(150)
                SB.collapse()
                await settle(150)
            }
            meter.finish(extra: "summon→drawn \(stats(latencies))")
        }

        private static func typeAndWait(_ tag: String) async {
            let word = "readme.md"
            let rounds = max(UserDefaults.standard.integer(forKey: "searchBarBenchmarkTypeRounds"), 1)
            await setQuery("")
            let meter = Meter("type-wait", tag)
            var latencies: [Double] = []
            for round in 0 ..< rounds {
                if round > 0 {
                    await setQuery("")
                }
                var typed = ""
                for ch in word {
                    typed.append(ch)
                    let start = CACurrentMediaTime()
                    typeCharacter(ch)
                    await waitForResults(typed)
                    latencies.append((CACurrentMediaTime() - start) * 1000)
                    await settle(120)
                }
            }
            meter.finish(extra: "key→results \(stats(latencies))")
        }

        private static func typeBurst(_ tag: String) async {
            await setQuery("")
            let word = "package.json"
            let meter = Meter("type-burst", tag)
            for ch in word {
                typeCharacter(ch)
                try? await Task.sleep(for: .milliseconds(55))
            }
            await waitForResults(word)
            meter.finish()
        }

        private static func arrows(_ tag: String) async {
            await setQuery("swift")
            let meter = Meter("arrows", tag)
            let moves = max(UserDefaults.standard.integer(forKey: "searchBarBenchmarkArrowMoves"), 60)
            let rows = max(SB.results.items.count, 1)
            for i in 0 ..< moves {
                // Down through the list and back up, so long runs keep scrolling.
                SB.moveSelection(by: (i / max(rows - 1, 1)) % 2 == 0 ? 1 : -1)
                try? await Task.sleep(for: .milliseconds(33))
            }
            await settle(300)
            let table = SB.results.tableView
            let selected = table.selectedRow
            let shown = selected >= 0 ? table.rowView(atRow: selected, makeIfNecessary: false)?.isSelected : nil
            meter.finish(extra: "rows \(SB.results.items.count), selected row highlighted: \(shown.map { "\($0)" } ?? "n/a")")
        }

        private static func listUpdates(_ tag: String) async {
            await setQuery("config")
            let base = FUZZY.results
            guard base.count > 10 else {
                log("list-updates: skipped, \(base.count) results")
                return
            }
            // Icons fetched for the previous scenario's rows make Cling re-sort its results, which
            // would replace the lists assigned here.
            _ = await waitForQuiet()
            let meter = Meter("list-updates", tag)
            let updates = max(UserDefaults.standard.integer(forKey: "searchBarBenchmarkListUpdates"), 30)
            for i in 0 ..< updates {
                let shift = (i * 7) % base.count
                FUZZY.results = Array(base[shift...] + base[..<shift])
                try? await Task.sleep(for: .milliseconds(60))
            }
            await settle(200)
            meter.finish()
            FUZZY.results = base
        }

        /// Files appearing at the top and disappearing further down, the way live index changes
        /// reach a list sorted by date.
        /// Renders the bar's own layer tree to PNGs, light and dark, over a list of system files that
        /// exist on every Mac. Offscreen and in-process: materials (glass, vibrancy) composite in the
        /// window server and come out as the flat fill behind them, everything else as on screen.
        private static func snapshots(prefix: String) async {
            let savedAppearance = Defaults[.windowAppearance]
            let savedPreview = Defaults[.searchBarShowPreview]
            defer {
                Defaults[.windowAppearance] = savedAppearance
                Defaults[.searchBarShowPreview] = savedPreview
                SB.panel?.appearance = nil
            }
            let paths = [
                "/Applications/Safari.app", "/System/Applications/Utilities/Terminal.app",
                "/System/Library/CoreServices/Finder.app", "/usr/bin/swift", "/System/Library/Fonts/Helvetica.ttc",
                "/private/etc/hosts", "/System/Library/Desktop Pictures", "/Library/Application Support",
                "/System/Library/CoreServices/SystemVersion.plist", "/usr/share/man/man1/ls.1",
            ].map { FilePath($0) }.filter { FileManager.default.fileExists(atPath: $0.string) }

            let savedPinned = Defaults[.searchBarPinned]
            Defaults[.windowAppearance] = .opaque
            AM.update()
            Defaults[.searchBarPinned] = true
            SB.collapse()
            await settle(600)
            for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                SB.benchmarkPillWindow?.appearance = appearance
                await settle(400)
                let file = "\(prefix)-pill-\(name).png"
                log(render(SB.benchmarkPillWindow, to: file, dark: name == "dark") ? "snapshot: \(file)" : "snapshot failed: \(file)")
            }
            SB.benchmarkPillWindow?.appearance = nil
            Defaults[.searchBarPinned] = savedPinned

            for (theme, preview) in [(WindowAppearance.opaque, false), (.opaque, true), (.vibrant, false)] {
                Defaults[.windowAppearance] = theme
                Defaults[.searchBarShowPreview] = preview
                AM.update()
                await setQuery("safari")
                // Twice: icons arriving for the first list make Cling re-sort its own results over it.
                FUZZY.results = paths
                await settle(1500)
                FUZZY.results = paths
                await settle(300)
                SB.moveSelection(by: 1)
                await settle(600)
                for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                    SB.panel?.appearance = appearance
                    await settle(500)
                    let file = "\(prefix)-\(theme.rawValue.lowercased())\(preview ? "-preview" : "")-\(name).png"
                    log(render(SB.panel, to: file, dark: name == "dark") ? "snapshot: \(file)" : "snapshot failed: \(file)")
                }
            }
        }

        private static func render(_ panel: NSWindow?, to file: String, dark: Bool) -> Bool {
            guard let panel, let view = panel.contentView, let layer = view.layer,
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            CATransaction.flush()
            let scale = panel.backingScaleFactor
            let size = view.bounds.size
            guard let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(dark ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            context.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, "public.png" as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        }

        /// Waits until the process used under a tenth of a core for a whole second, at most 90s.
        /// Returns the seconds waited.
        private static func waitForQuiet() async -> Int {
            let quietBy = Date().addingTimeInterval(90)
            var lastCPU = Meter.processCPUTime()
            var waited = 0
            while Date() < quietBy {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
                let cpu = Meter.processCPUTime()
                defer { lastCPU = cpu }
                if cpu - lastCPU < 0.1 {
                    break
                }
            }
            return waited
        }

        private static func listInserts(_ tag: String) async {
            await setQuery("config")
            let base = FUZZY.results
            guard base.count > 20 else {
                log("list-inserts: skipped, \(base.count) results")
                return
            }
            // Icons fetched for the previous scenario's rows make Cling re-sort its results, which
            // would replace the lists assigned here.
            _ = await waitForQuiet()
            let meter = Meter("list-inserts", tag)
            var list = base
            let updates = max(UserDefaults.standard.integer(forKey: "searchBarBenchmarkListUpdates"), 30)
            for i in 0 ..< updates {
                if i % 3 == 2 {
                    list.remove(at: min(5, list.count - 1))
                } else {
                    list.insert(FilePath("/private/tmp/cling-bench-churn/inserted-\(i).txt"), at: 0)
                }
                FUZZY.results = list
                try? await Task.sleep(for: .milliseconds(60))
            }
            await settle(200)
            meter.finish()
            FUZZY.results = base
        }

        private static func idleExpanded(_ tag: String) async {
            await setQuery("swift")
            let meter = Meter("idle-expanded+churn", tag)
            await churn(seconds: 6)
            meter.finish()
        }

        private static func idleCompact(_ tag: String) async {
            Defaults[.searchBarPinned] = true
            await settle(200)
            SB.collapse()
            await settle(300)
            let meter = Meter("idle-compact+churn", tag)
            await churn(seconds: 6)
            meter.finish()
            Defaults[.searchBarPinned] = false
            await settle(200)
        }

        /// Creates and deletes files in a scratch folder, about 40 changes a second, off the main thread
        /// so the file I/O itself doesn't count as main thread time.
        private static func churn(seconds: Double) async {
            await Task.detached(priority: .utility) {
                let dir = "/private/tmp/cling-bench-churn"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let end = CACurrentMediaTime() + seconds
                var i = 0
                while CACurrentMediaTime() < end {
                    let path = "\(dir)/file-\(i % 20).txt"
                    if i % 40 < 20 {
                        FileManager.default.createFile(atPath: path, contents: Data("churn \(i)".utf8))
                    } else {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                    i += 1
                    try? await Task.sleep(for: .milliseconds(25))
                }
                try? FileManager.default.removeItem(atPath: dir)
            }.value
        }

        /// Scrolls the tallest scroll view of the visible windows to its end.
        private static func scrollToEnd() {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                view.subviews.flatMap { sub -> [NSScrollView] in
                    let own = (sub as? NSScrollView).map { [$0] } ?? []
                    return own + scrollViews(in: sub)
                }
            }
            let windows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
            let tallest = windows.compactMap(\.contentView).flatMap(scrollViews(in:))
                .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            guard let scrollView = tallest, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let y = document.isFlipped ? max(document.frame.height - clip.bounds.height, 0) : 0
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        private static func showcase(_ query: String) async {
            if CommandLine.arguments.contains("-searchBarShowcaseDark") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            if let pane = argument("-searchBarShowcaseSettings") {
                SettingsNavigation.shared.selection = SettingsCategory(rawValue: pane) ?? .general
                WM.open("settings")
                await settle(1500)
                // `-searchBarShowcaseScrollToEnd` for the bottom of a long pane.
                if CommandLine.arguments.contains("-searchBarShowcaseScrollToEnd") {
                    scrollToEnd()
                }
                // Nothing focused, so a Mac with keyboard navigation on draws no focus ring on the first control.
                NSApp.keyWindow?.makeFirstResponder(nil)
                return
            }
            if CommandLine.arguments.contains("-searchBarShowcaseWindow") {
                FUZZY.query = query
                WM.open("main")
                return
            }
            // The main window on the live index changes.
            if CommandLine.arguments.contains("-searchBarShowcaseLiveIndex") {
                NSApp.activate(ignoringOtherApps: true)
                WM.open("main")
                FUZZY.showLiveIndex = true
                if query != "-" {
                    FUZZY.query = query
                }
                return
            }
            // The main window on the index size view, for its stats.
            if CommandLine.arguments.contains("-searchBarShowcaseIndexBrowser") {
                WM.open("main")
                FUZZY.showIndexBrowser = true
                return
            }
            // Settings > File server's Remote access sheet, in a window of its own: the pane only offers it while the
            // server runs, which needs Pro.
            if CommandLine.arguments.contains("-searchBarShowcaseRemoteAccess") {
                let window = NSWindow(contentViewController: NSHostingController(rootView: RemoteAccessSheet()))
                window.title = "Remote access"
                window.center()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                showcaseWindow = window
                return
            }
            if CommandLine.arguments.contains("-searchBarShowcaseCheatsheet") {
                let window = NSWindow(contentViewController: NSHostingController(rootView: QuerySyntaxCheatsheet().frame(height: 560)))
                window.title = "Search syntax"
                window.center()
                window.makeKeyAndOrderFront(nil)
                showcaseWindow = window
                await settle(800)
                scrollToEnd()
                return
            }
            if CommandLine.arguments.contains("-searchBarShowcaseEverything") {
                // Everything turns on once Pro is confirmed, a moment after launch.
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline, !EVERYTHING.enabled || EVERYTHING.loading || EVERYTHING.engine == nil {
                    if !EVERYTHING.enabled, proactive {
                        EVERYTHING.toggle()
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            if let id = argument("-searchBarShowcaseFilter") {
                FUZZY.quickFilter = Defaults[.quickFilters].first { $0.id.lowercased() == id.lowercased() }
            }
            if let folder = argument("-searchBarShowcaseFolder") {
                let path = (folder as NSString).expandingTildeInPath
                let name = path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent
                FUZZY.folderFilter = FolderFilter(id: name, folders: [FilePath(path)], key: nil)
            }
            // `-` leaves the bar closed, for the pinned field.
            guard query != "-" else { return }
            let readyBy = Date().addingTimeInterval(120)
            while Date() < readyBy, FUZZY.indexedCount == 0 || FUZZY.indexing {
                try? await Task.sleep(for: .milliseconds(250))
            }
            await settle(1000)
            await setQuery(query)
            await settle(1500)
            SB.moveSelection(by: 1)
        }

        private static func argument(_ name: String) -> String? {
            CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments[safe: $0 + 1] }
        }

    }

    extension SearchBarController {
        /// What the benchmark waits on: the query and search state the bar last applied.
        var benchmarkState: (query: String, searching: Bool)? {
            guard let inputs = lastAppliedInputs else { return nil }
            return (inputs.query, inputs.searching)
        }
    }

#endif
