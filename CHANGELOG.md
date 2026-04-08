# 2.1.3
## Improvements

- Search results now automatically refresh after **Apply & Reindex** or volume reindexing finishes
- Ignored files in volume `.fsignore` files are now properly excluded from the recents engine, both during reindex and live indexing

## Changes

- Time Machine backup volumes are no longer enabled for indexing by default

## Fixes

- **Apply & Reindex** now ensures the ignore file is saved to disk before starting the reindex

# 2.1.2
## Improvements

- **Copy to...** and **Move to...** now remember the last destination path per file extension
    - e.g. if you usually copy PDFs to `~/Documents/Invoices`, that path will be pre-filled next time
- **Open With** panel now uses fuzzy matching for filtering apps

## Fixes

- **Copy to...** and **Move to...** no longer create a directory when copying/moving a single file to a path without a trailing slash
- Recents list no longer gets wiped out when reindexing a volume
- Volume `.fsignore` patterns now work correctly
- Home scope no longer indexes files inside enabled volume mount points (e.g. `~/filen`)
    - Volumes mounted under the home directory were being walked twice: once by the home scope and once by the volume indexer
- `cling reindex --scope <name>` now resolves volume names, not just scope names

# 2.1.1
## Fixes

- `cling reindex --wait` actually waits for indexing to finish again
- Reindexing the **Home** scope no longer crashes when `/Users/Shared` is present
- Running `cling reindex` while another reindex is already in progress now gives a clear message instead of silently doing nothing

## CLI improvements

- `cling status --json` outputs structured status for scripting, including per-scope and per-volume progress
- `cling reindex --wait` shows live per-scope progress so you can tell exactly which scope is being worked on
- `cling reindex --scope <name> --wait` can safely attach to an in-progress reindex of that scope instead of hanging

# 2.1.0
## Features

- **Onboarding window** on first launch to choose window mode, style, hotkey, volumes, and grant **Full Disk Access**
- Volume and folder filter indexing status shown in the filter picker (*Not indexed* / *Indexing...*)
- Selecting an unindexed volume starts indexing automatically
- **Parallel volume indexing** with per-volume cancel support
- **Reindex All / Cancel All** buttons for scopes and volumes in Settings
- `cling reindex --cancel` to cancel indexing from the CLI
- `cling status` now shows per-scope and per-volume entry counts and **indexing progress**
- Super fast **SMB indexing** and metadata caching for network volumes
- Faster indexing for non-network volumes using `FTS_NOSTAT`

## Changes

- Shelve shortcut changed from `⌘F` to `⌘S` to match the Raycast extension and avoid conflicts with the common *Find* shortcut
- **Settings sections** are now collapsible
- Settings reorganized: window settings grouped together, default apps in their own section
- Enabled volumes are now indexed automatically on launch
- Selecting a volume filter deselects folder filters and vice versa

## Fixes

- CLI installation now preserves symlinked shell configs (`.zshrc`, `.bashrc`, `config.fish`) instead of replacing them with regular files
- **Indexing progress** stays visible in the status bar during filter changes
- Empty volume indexes are no longer saved to disk

# 2.0.1
## Features

- Copy to folder (⌘⌥C)
- Move to folder (⌘M)
- Copy filenames (⌘⌥⇧C)
- Hold `Option` to see alternate actions in the toolbar

## Fixes

- Ignoring a folder in the ignore file now properly removes all its contents from search results
- Ignoring a specific file now works correctly after reindexing

## Improvements

- Library scope is now available in the free version
- Reindex button for each search scope in Settings
- CLI `reindex` command now accepts volume paths (e.g. `cling reindex --scope /Volumes/MyDrive`)
- Option to use `~/` or full home dir path when copying paths
- Folder search accepts trailing slashes

# 2.0.0
## Cling 2.0: New Search Engine

The search engine has been **completely rewritten from scratch**. Cling no longer depends on any external tools, everything runs natively inside the app.

### What's different

- **File-path specific fuzzy search index** returns more relevant results than `fzf`
- **Searches complete in under 100ms** across millions of files, using all your CPU cores in parallel and SIMD accelerated instructions
- **Persistent binary indexes** load instantly on launch
- **Live filesystem tracking** is faster and more reliable

### New features

- **Quick Filters** updated to support new fields:
    - `Extensions: .pdf .docx` to filter by extension
    - `Dirs only` to search only folders
    - `Pre and post-queries` to prepend or append query parts automatically
- **Extension queries**: type `.png icon` or `invoice .pdf` to narrow results by extension
- **Search history**: navigate previous searches with arrow keys, autocomplete with `Tab`
- **Smart defaults**: your most recently changed files appear when you open Cling
- **CLI tool**: search from the terminal with the `cling` command
    - `cling "invoice .pdf"` searches for "invoice" with a `.pdf` extension filter, just like in the app
    - `cling index remove ~/.config` removes all files in the `~/.config` directory from the index
    - `cling reindex --scope home` forces a reindex of the Home scope
    - `cling search --scope library --suffix .app --dirs-only -- "updater"` searches for Updater apps
- **File shelf apps**: send files to apps like Yoink with a hotkey
- **Live index viewer**: view a list of most recent changes to the filesystem and index in real time
- **Liquid Glass**: fully optional, with alternative *Opaque* and *Vibrant* themes
- **Run history**: keeps track of files you acted on
- **Script engine**: more options for limiting on what files scripts can run:
    - "Print document" can be set to not appear for folders
    - "Diff" can be set to only appear when 2 files are selected
    - *etc.*

---

### Cling Pro

Cling is now **free to use** with `Home` and `Applications` search scopes, with up to 500 results and most instant actions.

A **Cling Pro** license unlocks:

- additional scopes: `Library`, `System`, `Root`
- external volume indexing
- Quick Filters
- Folder Filters
- Scripts
- up to **10,000 results**

Notes:
- **14-day free trial** of all Pro features, no payment details needed
- After the trial, the app keeps working in Free mode
- Pro license: **€12**, one-time, for life, up to 5 Macs
- Activating a 6th Mac automatically deactivates the oldest one, so the license can be used indefinitely as you change machines

*Cling v1 remains available and free forever for users who prefer it, but all new development is focused on v2.*

---

### Fixes

- Fixed the PTY leak that required periodic app restarts in v1.2
- Fixed Full Disk Access detection on macOS Sequoia with SIP disabled

### Improvements

- Improved handling of deleted files in the index
- Dock icon can be shown now with a setting
- Unicode searches now work correctly
- Columns are resizable instead of fixed width

# 1.2
## Features

- **External Volumes** support: index and search external volumes like USB drives, network shares, etc.

![cling volume support settings and UI](https://files.lowtechguys.com/cling-volume-support.png)

## Fixes

- Fix search not ignoring Library files after disabling Library indexing
- Don’t launch Clop when checking if the integration is available

## Improvements

- Add "Launch at login" option in Preferences
- Show indexing progress in the status bar
- Hide QuickLook on Esc key press
- Show `Space` as a shortcut for QuickLook when the results list is focused
- Restart `fzf` with a more limited scope when Folder/Volume filters are used to make search faster
- Sort by kind

# 1.2.2
## Improvements

- Update to fzf 0.64.0

## Fixes

- Fix Full Disk Access not being detected correctly when SIP is disabled
- Relaunch the app periodically every 12 hours to avoid search not working because of PTY leaks *(workaround until a proper fix is implemented)*

# 1.2.1
## Fixes

- Fix **Execute script** hotkey being shown as the wrong key

# 1.1
## Fixes

- **Fix search not showing any results when typing**
- Fix double query sending
- Make gitignore syntax help text fit window width

## Improvements

- Show summon hotkey on the indexing screen
- Pause indexing on low battery (`< 30%`)
- Show when Full Disk Access is not granted

## Features

- Add **Copy paths** and **Copy filenames** to the right click menu
- Add *Faster search, with less optimal results* option
- Add *Keep window open when the app is in background* option
- Add **Exclude from index** option to the right click menu
- Add Quit button
- Add default scripts to serve as examples:
    - `Copy to temporary folder`
    - `Archive`
    - `List archive contents` (this one exemplifies how to limit the extensions on which the script appears and how to show output)

# 1.0
Initial release
