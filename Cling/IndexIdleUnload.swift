import Defaults
import Foundation
import Lowtech
import os.log

private let log = Logger(subsystem: clingSubsystem, category: "IndexIdleUnload")

extension Defaults.Keys {
    /// Minutes without a search, and with no Cling window on screen, after which the scope indexes are unloaded until
    /// the next search. 0 keeps them loaded.
    static let unloadIndexAfterIdleMinutes = Key<Int>("unloadIndexAfterIdleMinutes", default: 0)
}

// MARK: - Unloading the scope indexes while idle

/// With `unloadIndexAfterIdleMinutes` set, the scope engines are saved and let go after that long without a search
/// while no Cling window is on screen. The file change stream keeps running: what changes in an unloaded scope is set
/// aside per path (`ParkedChanges`) and applied when the scope is loaded again, which happens on the hotkey, on the
/// window showing, or on a CLI call that needs the index, Home first. A scope that gathers too many changes meanwhile
/// replays its FSEvents history from where its file was saved instead, as at launch.
@MainActor
extension FuzzyClient {
    /// Some scope indexes are unloaded, or on their way out.
    var indexUnloaded: Bool {
        !unloadedScopes.isEmpty
    }

    func noteIndexUse() {
        lastIndexUse = Date()
    }

    /// How long without a search before unloading. `-unloadIndexAfterIdleSeconds N` stands in for the minutes, to
    /// try it without waiting.
    static var idleUnloadDelay: TimeInterval {
        let seconds = UserDefaults.standard.integer(forKey: "unloadIndexAfterIdleSeconds")
        return seconds > 0 ? TimeInterval(seconds) : TimeInterval(Defaults[.unloadIndexAfterIdleMinutes] * 60)
    }

    /// Run every minute, or more often for a delay under two minutes.
    func unloadIndexIfIdle() {
        let delay = Self.idleUnloadDelay
        guard delay > 0, unloadedScopes.isEmpty, reloadTask == nil, !windowOnScreen.value,
              Date().timeIntervalSince(lastIndexUse) >= delay,
              !loadingIndex, !indexing, !backgroundIndexing, scopesIndexing.isEmpty,
              let updater = liveUpdater, updater.replay.caughtUp, !scopeEngines.isEmpty
        else { return }
        unloadIndex(updater)
    }

    /// Sends the scopes' changes aside, then once no batch is still being applied to them, saves what changed and lets
    /// the engines go. Their positions stay where their files were saved until they are loaded again, so a quit in
    /// between replays from there at the next launch.
    func unloadIndex(_ updater: LiveIndexUpdater) {
        let engines = scopeEngines.filter { searchableScopes.contains($0.key) }
        guard !engines.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        for (scope, engine) in engines {
            unloadedScopes[scope] = engine.count
            frozenScopes.insert(scope)
        }
        updater.setRoutes(liveRoutes()) { [weak self] in
            let applied = updater.lastAppliedEventID
            Task { @MainActor in
                self?.finishUnload(engines, applied: applied, started: t0)
            }
        }
    }

    private func finishUnload(_ engines: [SearchScope: SearchEngine], applied: UInt64, started t0: CFAbsoluteTime) {
        // A reload asked for meanwhile already took some back.
        let leaving = engines.filter { unloadedScopes[$0.key] != nil && scopeEngines[$0.key] === $0.value }
        guard !leaving.isEmpty else { return }
        for scope in leaving.keys {
            if let base = liveBase[scope], base < applied {
                liveBase[scope] = applied
            }
        }
        let positions = liveBase.filter { leaving.keys.contains($0.key) }
        let rules = liveRules
        unloadTask = Task {
            await Task.detached(priority: .utility) {
                for (scope, engine) in leaving {
                    let file = scopeIndexFile(scope)
                    if engine.hasUnsavedChanges || !file.exists {
                        engine.saveBinaryIndex(to: file.url)
                    }
                }
                ScopeIndexState.save(positions, rules: rules)
            }.value
            unloadTask = nil
            var released = 0
            for (scope, engine) in leaving where unloadedScopes[scope] != nil && scopeEngines[scope] === engine {
                releaseInBackground(scopeEngines.removeValue(forKey: scope))
                released += 1
            }
            guard released > 0 else { return }
            quickFilterPools.removeAll()
            updateIndexedCount()
            invalidateSearch()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log.info("Index unloaded after \(Int(Self.idleUnloadDelay))s idle: \(released) scopes in \(ms, format: .fixed(precision: 0))ms")
        }
    }

    /// Loads the unloaded scopes again, Home first, each searched as soon as it is in, then hands them their changes
    /// from while they were out. `then` runs once all are back.
    func reloadIndex(then: (@MainActor () -> Void)? = nil) {
        if let then {
            reloadWaiters.append(then)
        }
        guard !unloadedScopes.isEmpty else {
            runReloadWaiters()
            return
        }
        guard reloadTask == nil else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let order = searchableScopes.sorted { a, _ in a == .home }.filter { unloadedScopes[$0] != nil }
        reloadTask = Task {
            // An unload still saving lets go of nothing once these are back, and its file is complete when it's done.
            await unloadTask?.value
            var failed: [SearchScope] = []
            for scope in order where scopeEngines[scope] == nil {
                let file = scopeIndexFile(scope)
                let engine = await Task.detached(priority: .userInitiated) { () -> SearchEngine? in
                    let engine = SearchEngine()
                    return engine.loadBinaryIndex(from: file.url) ? engine : nil
                }.value
                guard let engine else {
                    failed.append(scope)
                    continue
                }
                scopeEngines[scope] = engine
                syncCoordinator()
                if scope == order.first {
                    invalidateSearch()
                    performSearch()
                }
            }
            let back = order.filter { scopeEngines[$0] != nil }
            for scope in order {
                unloadedScopes[scope] = nil
            }
            // What changed while they were out is applied before anything waiting on the reload goes ahead, so a CLI
            // call that loaded the index sees it.
            // With no stream running to hand them over, they replay from where their files were saved.
            var overflowed = back
            if let updater = liveUpdater {
                overflowed = await withCheckedContinuation { done in
                    updater.resume(back, routes: liveRoutes()) { done.resume(returning: $0) }
                }
            } else {
                for scope in back {
                    parkedChanges.discard(scope)
                }
            }
            resumed(back, overflowed: overflowed)
            if !failed.isEmpty {
                log.error("Index reload: no readable file for \(failed.map(\.rawValue)), walking them")
                for scope in failed {
                    frozenScopes.remove(scope)
                    liveBase[scope] = nil
                }
                indexFiles(pauseSearch: false, scopes: failed) { [self] in watchFiles() }
            }
            updateIndexedCount()
            invalidateSearch()
            performSearch()
            recomputeQuickFilterPool()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            log.info("Index reloaded: \(back.map(\.rawValue)) in \(ms, format: .fixed(precision: 1))ms")
            reloadTask = nil
            runReloadWaiters()
        }
    }

    /// The parked changes are in. A scope that gathered too many replays its history from where its file was saved, or
    /// is walked when that is too far back.
    private func resumed(_ scopes: [SearchScope], overflowed: [SearchScope]) {
        for scope in scopes where !overflowed.contains(scope) {
            frozenScopes.remove(scope)
        }
        guard !overflowed.isEmpty else { return }
        let now = FSEventsGetCurrentEventId()
        let walk = overflowed.filter { liveBase[$0].map { now - $0 > Self.maxReplayGap } ?? true }
        log.info("Index reload: \(overflowed.map(\.rawValue)) changed too much while unloaded, replaying from their saved positions")
        // The stream restarts from the oldest position, theirs, while they are still held back from advancing.
        watchFiles()
        for scope in overflowed {
            frozenScopes.remove(scope)
        }
        if !walk.isEmpty {
            for scope in walk {
                liveBase[scope] = nil
            }
            indexFiles(pauseSearch: false, scopes: walk) { [self] in watchFiles() }
        }
    }

    /// A walk replaced the scope's engine: what was set aside for it is already in.
    func forgetUnloaded(_ scope: SearchScope) {
        unloadedScopes[scope] = nil
        frozenScopes.remove(scope)
        parkedChanges.discard(scope)
    }

    private func runReloadWaiters() {
        let waiters = reloadWaiters
        reloadWaiters.removeAll()
        for waiter in waiters {
            waiter()
        }
    }

    /// For CLI calls that need the index, from a listener thread: loads it when unloaded and waits for it, up to a
    /// minute.
    nonisolated static func waitForLoadedIndex() {
        let loaded = DispatchSemaphore(value: 0)
        let needed = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                FUZZY.noteIndexUse()
                guard FUZZY.indexUnloaded else { return false }
                FUZZY.reloadIndex { loaded.signal() }
                return true
            }
        }
        if needed {
            _ = loaded.wait(timeout: .now() + 60)
        }
    }
}
