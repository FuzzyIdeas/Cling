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

        private static func log(_ line: String) {
            lines.append(line)
            print(line)
        }

        private static func run() async {
            let outPath = CommandLine.arguments.firstIndex(of: "-searchBarBenchmarkOut")
                .flatMap { CommandLine.arguments[safe: $0 + 1] } ?? "/private/tmp/cling-searchbar-bench.txt"

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

            let savedAppearance = Defaults[.windowAppearance]
            let savedPreview = Defaults[.searchBarShowPreview]
            let savedPinned = Defaults[.searchBarPinned]
            let savedQuery = FUZZY.query

            var appearances: [WindowAppearance] = [.vibrant, .opaque]
            if #available(macOS 26, *) {
                appearances.insert(.glassy, at: 0)
            }

            for appearance in appearances {
                Defaults[.windowAppearance] = appearance
                AM.update()
                try? await Task.sleep(for: .milliseconds(300))
                for preview in [false, true] {
                    Defaults[.searchBarShowPreview] = preview
                    try? await Task.sleep(for: .milliseconds(100))
                    let tag = "\(appearance.rawValue.lowercased())\(preview ? "+preview" : "")"
                    log("")
                    log("## \(tag)")
                    await expandCollapse(tag)
                    await typeAndWait(tag)
                    await typeBurst(tag)
                    await arrows(tag)
                    await listUpdates(tag)
                }
                await idleExpanded(appearance.rawValue.lowercased())
                await idleCompact(appearance.rawValue.lowercased())
            }

            SB.collapse()
            Defaults[.windowAppearance] = savedAppearance
            Defaults[.searchBarShowPreview] = savedPreview
            Defaults[.searchBarPinned] = savedPinned
            AM.update()
            FUZZY.suppressNextSearch = true
            FUZZY.query = savedQuery

            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
            print("Benchmark written to \(outPath)")
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
            await setQuery("")
            let word = "readme.md"
            let meter = Meter("type-wait", tag)
            var latencies: [Double] = []
            var typed = ""
            for ch in word {
                typed.append(ch)
                let start = CACurrentMediaTime()
                typeCharacter(ch)
                await waitForResults(typed)
                latencies.append((CACurrentMediaTime() - start) * 1000)
                await settle(120)
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
            for _ in 0 ..< 60 {
                SB.moveSelection(by: 1)
                try? await Task.sleep(for: .milliseconds(33))
            }
            await settle(300)
            meter.finish(extra: "rows \(SB.results.items.count)")
        }

        private static func listUpdates(_ tag: String) async {
            await setQuery("config")
            let base = FUZZY.results
            guard base.count > 10 else {
                log("list-updates: skipped, \(base.count) results")
                return
            }
            let meter = Meter("list-updates", tag)
            for i in 0 ..< 30 {
                let shift = (i * 7) % base.count
                FUZZY.results = Array(base[shift...] + base[..<shift])
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

        /// Creates, edits and deletes files in a scratch folder, about 40 changes a second.
        private static func churn(seconds: Double) async {
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
