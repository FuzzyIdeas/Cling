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
