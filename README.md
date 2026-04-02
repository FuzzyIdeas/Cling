<p align="center">
    <a href="https://lowtechguys.com/cling"><img width="128" height="128" src="Cling/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" style="filter: drop-shadow(0px 2px 4px rgba(80, 50, 6, 0.2));"></a>
    <h1 align="center"><code style="text-shadow: 0px 3px 10px rgba(8, 0, 6, 0.35); font-size: 3rem; font-family: ui-monospace, Menlo, monospace; font-weight: 800; background: transparent; color: #4d3e56; padding: 0.2rem 0.2rem; border-radius: 6px">Cling</code></h1>
    <h4 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace;">Instant fuzzy find any file</h4>
    <h6 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace; font-weight: 400;">Act on it in the same instant</h6>
</p>

<p align="center">
    <a href="https://files.lowtechguys.com/releases/Cling.dmg">
        <img width=200 src="https://files.lowtechguys.com/macos-app.svg">
    </a>
</p>

### Installation

- Download the app from the [website](https://lowtechguys.com/cling) and drag it to your `Applications` folder
- If you use [homebrew](https://brew.sh/), run `brew install --cask thelowtechguys-cling`

![screenshot](https://lowtechguys.com/static/img/cling-ui.png)

### Features

- **Fuzzy search across millions of files** in under 100ms
- **Quick Filters** for file types (Images, Videos, Documents, Code, PDFs, etc.) and folder restrictions
- **Act on files instantly** with hotkeys, scripts, drag and drop, or batch rename
- **Smart defaults** showing your most recently changed files on launch
- **Search history** with `Up`/`Down` arrow cycling, `Tab` completion, and `Cmd+Down` to browse all history
- **Extension-aware queries** like `.png icon` or `.pdf invoice`
- **Configurable search scopes** (Home, Library, Applications, System, Root) with `.fsignore` support
- **External volume indexing** with persistent indexes that work even when unmounted
- **Live filesystem tracking** via FSEvents
- **CLI tool** for terminal-based searching
- **Everything for Mac** with native macOS integration

---

### Pro features

Cling is free to use with Home, Library and Applications search scopes. A **Cling Pro** licence unlocks:

- **Additional search scopes**: System, Root
- **External volume indexing** with persistent indexes
- **Quick Filters** for file types and custom queries
- **Custom folder filters** for saved folder sets
- **Scripts** to run custom actions on files
- **Up to 10,000 results** (free is capped at 500)

### Pricing

Cling starts with a **14-day free trial** automatically, no payment details needed. After the trial, the app continues to work in **Free mode** with Home, Library and Applications scopes, up to 500 results.

A Pro license costs **€12**, one-time purchase, for life. It can be activated on up to **5 personal Mac devices**.

*Activating a 6th Mac automatically deactivates the oldest one, so the license can be used indefinitely as you change machines.*

---

### Comparison with other apps

#### Spotlight, Alfred, Raycast

Cling is similar to these apps in that it provides instant search results, but the key differences are:

- **Fuzzy search**: find files with partial or misspelled queries
- **System files**: search system files, hidden files, dotfiles, and app data that the Spotlight index doesn't include
- **Extension filtering**: quickly narrow results by file type without crafting complex queries

#### ProFind, HoudahSpot, EasyFind, Tembo, Find Any File

Cling is very much **not** like these apps.

They are all file search apps that provide advanced search features, allowing you to craft complex queries using metadata and file content to dig deep into your filesystem and find as many files as possible.

Cling is for quickly finding one or more specific files by roughly knowing the name, and then doing something with the file immediately like:

- copying it for sending on chat
- adding to a shelf like Yoink
- opening it in an app like Pixelmator
- uploading it using Dropshare
- executing a script on the file

**Cling is not an app for finding all files that match a complex query.**

---

### Performance considerations

#### Memory usage

To provide instant search results, Cling maintains an in-memory index of your filesystem split across separate engines for each search scope. This can consume a significant amount of memory, ranging from `300MB` to `2GB` depending on the size of your filesystem and the number of files indexed.

Whenever Cling is in background *(the window is not visible)*, the index will be marked as **swappable to disk**. This allows macOS to move the index to disk and free up RAM when memory pressure is high. Cling will reload the index from disk when you open its window again.

#### CPU usage

The most CPU-intensive operations are:

- **Indexing**: when Cling is indexing your filesystem for the first time, it will consume a significant amount of CPU for about 1 to 5 minutes
- **Re-indexing**: periodically, about once every 3 days, Cling will re-index the filesystem to keep the index up-to-date
- **Fuzzy search**: when you type in the search bar, Cling performs a parallel fuzzy search across all active engines

Searching will consume CPU in short bursts. In a Release build, a typical search across 9+ million files completes in under 100ms. When Cling is in background, it will pause searching and consume very little CPU for processing file changes.

#### Battery usage

The impact on battery is proportional to how many searches you do and how many file changes happen in the background.

Even though a search will look like it's consuming 100% CPU of multiple cores, it's a very fast operation and the battery energy used isn't that high in the long term.

Processing and indexing file changes is very efficient and will not impact battery life significantly.

---

### How it works

```
Filesystem ──► fts_read (local) / FileManager (external)
                        │
                        ▼
              ┌───────────────────────┐
              │  Binary Index (.idx)  │  one per scope/volume
              │  parallel arrays:     │  persists across launches
              │   · path bytes (LC)   │
              │   · 64-bit bitmasks   │
              │   · basename bitmasks │
              │   · word boundaries   │
              │   · extension IDs     │
              └────────┬──────────────┘
                       │ load (mmap + memcpy)
                       ▼
              ┌───────────────────────┐
              │  Search Engines       │◄── FSEvents (live updates)
              │  · per-scope (Home,   │◄── MDQuery  (recents)
              │    Apps, Library, …) │
              │  · per-volume         │
              │  · recents            │
              └────────┬──────────────┘
                       │
                    query  →  parse into fuzzy / extension /
                              folder / dir-segment tokens
                       │
                       ▼
              Phase 1: Filter (parallel across cores)
               · 64-bit bitmask precheck
               · extension ID (UInt16 compare)
               · folder prefix (sorted index or byte scan)
               · dir-segment literal substring
               · excluded paths (O(1) set lookup)
               · QuickFilter pre-filtered pools
                       │
                       ▼
              Phase 2: Score (parallel across cores)
               · fzf fuzzy scoring (basename + full path)
               · multi-token independent scoring
               · SIMD byte search for long paths
               · boundary/camelCase/delimiter bonuses
                       │
                       ▼
              Multi-engine Orchestration
               · best engine first → instant results
               · remaining engines in parallel (TaskGroup)
                       │
                       ▼
              Merge + Rank
               · quality gate (top-third filter)
               · composite rank: score, importance,
                 prefix match, basename match, depth
               · deduplicate by path
                       │
                       ▼
                    Results
```
