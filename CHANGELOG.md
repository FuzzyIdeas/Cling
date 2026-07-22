# 2.6.8

**[Download Cling 2.6.8 →](https://files.lowtechguys.com/releases/Cling-2.6.8.dmg)**
## Fixes

- A slow filesystem-event startup step no longer risks freezing the app a few minutes after launch
- No more freeze when a selected file sits on a slow or disconnected drive, caused by the script action bar checking each file's type on the main thread
- No more freeze during the periodic background reindex, caused by a cache refresh that could stall behind the running scan
- Settings sidebar no longer collapses out of view with no way to reopen it

## Improvements

- If the app ever quits unexpectedly, it now restarts itself and saves a crash report each time, so the cause can be tracked down
- Restyled settings sidebar

# 2.6.7

**[Download Cling 2.6.7 →](https://files.lowtechguys.com/releases/Cling-2.6.7.dmg)**
## Fixes

- No more crash at launch when a slow external disk is connected (camera SD cards, USB drives), caused by a volume check that could time out and abort the app
- No more freeze at launch when a connected drive is slow to respond, caused by a mounted-volume check running on the main thread

# 2.6.6

**[Download Cling 2.6.6 →](https://files.lowtechguys.com/releases/Cling-2.6.6.dmg)**
## Features

- **Stash**: press `⌘S` to pin the selected files to a stash that stays above the results while you keep searching
    > Fully editable: `⌘S` again unstashes, right-click adds or removes files, and the red trash button in its header (or `⌘⇧S`) empties it. The stash survives restarts.
    >
    > Stashed rows keep every file action: open, Quick Look, copy, send, drag out, trash
    >
    > Files can auto-clear after a chosen time, set in *Settings -> Open with*

- **Sort shortcuts** reorder results from the keyboard, rebindable in Settings, under Shortcuts
    > `⌃N` Name · `⌃P` Path · `⌃S` Size · `⌃D` Date · `⌃0` Relevance
    >
    > Press the same key again to flip between ascending and descending
    >
    > Hold `⌘` to see each column's sort shortcut in its header
    >
    > Clicking the Size or Date Modified column header now sorts largest and newest first; Name and Path still start ascending

- **Add files to an active room**: select more files and press *Add to this room* in the *Transfers* panel to put them into a *Send Securely* link you already shared

- **Hide toolbar rows**: right-click the action, *Open with*, or script row for a quick hide option
    > Double-tap a modifier key of your choice (set in *Settings > Style > Rows*) to hide or show all three rows at once
    >
    > With every row hidden, the results table takes over the freed space

## Fixes

- No more freezes of 30+ seconds at launch when Spotlight is slow to return the recent files (on busy or slow disks)
- Files saved again by an editor or re-synced by a cloud service (Dropbox, iCloud) no longer disappear from search until the next restart; they reappear the moment they're written back to disk
- `⌘⌫` moves the selected files to the trash again, and the shortcut hints shown while holding `⌘` no longer disappear for good after trying to trash
- Files with Korean or accented names no longer go missing from multi-word searches or rank below less relevant results

## Improvements

- Script shortcut hints use a warm amber in dark mode instead of the hard-to-read dark red

# 2.6.5

**[Download Cling 2.6.5 →](https://files.lowtechguys.com/releases/Cling-2.6.5.dmg)**
## Fixes

- Multi-word searches for files with Korean, Japanese, or accented names now find the file even when extra text sits between your search terms
- A slow or unresponsive drive no longer freezes the app while showing search results or tidying up after indexing
- Loading the list of installed apps (used for the Open With menu) no longer risks a brief freeze

# 2.6.4

**[Download Cling 2.6.4 →](https://files.lowtechguys.com/releases/Cling-2.6.4.dmg)**
## Features

- **`cling explain`** tells you whether a path is in the index, and if it isn't, which rule is keeping it out (a disabled scope, the blocklist, or an ignore file)

## Fixes

- Big searches no longer freeze the app; result lists with thousands of matches now show up instantly and stay smooth to scroll
- Connecting or ejecting a drive no longer risks a freeze while the app refreshes its list of volumes
- Quick filters that combine several file types (Config, Images, Documents, Code, and the other multi-type filters) showed no results; they now match files of any of the listed types
- Renaming a quick filter is reliable now; the name field no longer loses your edits as you type
- Fixed a crash that could happen when searching with a quick filter active while the index was being rebuilt in the background
- Quick filter results now stay accurate right after a background reindex, instead of going briefly stale

# 2.6.3

**[Download Cling 2.6.3 →](https://files.lowtechguys.com/releases/Cling-2.6.3.dmg)**
## Fixes

- No more long freezes (beachball) while refreshing recent files, loading app icons, or finishing indexing; that work now runs in the background so the window stays responsive
- The filter menu shows each filter's `⌥` shortcut on the right again

## Improvements

- Filters with long extension or folder lists no longer stretch the filter menu; the detail line shortens to the first few with `+N more`, and the full list shows when you hover

# 2.6.2

**[Download Cling 2.6.2 →](https://files.lowtechguys.com/releases/Cling-2.6.2.dmg)**
## Improvements

- Searching by file type alone (like `.m4a`) ranks your own music, movies, and photos above system and app files, and stops large libraries from being cut off before your file shows up

# 2.6.1

**[Download Cling 2.6.1 →](https://files.lowtechguys.com/releases/Cling-2.6.1.dmg)**
## Features

- **Search operators** to filter and exclude results as you type
    > Exclude: `!word` hides matches · `!.png` hides a file type · `!/` shows files only
    >
    > Exact: `'word` matches the text exactly, not loosely
    >
    > Anchor: `^word` (name starts with it) · `word$` (name ends with it)
    >
    > Tap `?` in the search bar for the full list, including `.png`, `in:~/Downloads`, and `depth:1`

- **Step into folders**: select a folder in the results, press `→` to search inside it and `←` to step back out

- **Opt-in indexing for new volumes**: a drive or share you connect stays unindexed until you switch it on yourself
    > Turn on *Don't index new volumes automatically* in Settings, under Drives & Volumes. It's off by default, so volumes keep indexing on connection unless you change it.
    >
    > Switch volumes on one at a time; volumes you've already indexed keep refreshing on their own.

- **Fine-tune index rules before applying them**, both when you add an excluded path back and when you exclude files
    > Click a folder name to match any folder in that spot, or click a file like `clip.mp4` to match `*.mp4` (any file of that type), then `*` for anything.
    >
    > Edit any rule as plain text, and switch individual rules on or off so only the ones you want apply.
    >
    > A live check confirms your edited rule still covers the path you picked, and the exclude dialog estimates how many indexed items it would affect.

## Fixes

- License and purchase dialogs open as a sheet inside Settings, fixing a case where that window couldn't be clicked
- Searches with accented letters (like `é` or `ñ`) match file names that use those accents

## Improvements

- `in:` searches list only what's inside the folder, not the folder itself
- A folder name typed with a trailing slash (`photos/`) turns up the folder itself, not only its contents
- The per-volume reindex interval slider snaps to clean values like `1 hour`, `1 day`, or `1 week`, so it no longer settles on odd intervals like `6 days 23 hours`

# 2.6.0

**[Download Cling 2.6.0 →](https://files.lowtechguys.com/releases/Cling-2.6.0.dmg)**
## Features

- **Send securely** shares the selected files over an encrypted (peer-to-peer, auto-expiring) link
    > Files transfer straight from your Mac, so a link only works while you're sharing it.
    >
    > Send the selected files without touching the mouse: `⌘U`, then `Return`
    >
    > **Transfers** panel on the Send button shows each active link's download count, a live countdown to expiry, and lets you copy, reschedule, or stop it
    >
    > A notification tells you when someone finishes downloading a file you sent
- **Redesigned action toolbar**: actions are grouped into sections with the less-used ones moved into a `⋯` menu, so the row stays clean and glanceable
    > Restyle the toolbar to taste: *icon-and-text*, *text-only*, or *icon-only* buttons, *regular* or *compact* spacing, optional dividers and background
    >
    > Decide where each action lives, in the **Action bar**, the `⋯` **Action menu**, or *hidden*
    >
    > Each app is keyed by the first letter of its name; when several apps share a letter, that key opens an app picker
    >
    > Hold `⌘` to reveal every action's shortcut right on its button, or `⌘⌥` and `⌘⌃` for the *Open With* and *Scripts* rows
- **Custom shortcuts**: rebind any toolbar action's keyboard shortcut in Settings, under Shortcuts

## Improvements

- The results table, preview panel, and action row corners match the window's rounding

# 2.5.0

**[Download Cling 2.5.0 →](https://files.lowtechguys.com/releases/Cling-2.5.0.dmg)**
## Features

- **Group toggles** turn whole sets of exclusion rules on or off without writing any gitignore syntax
- **Exclude from Index** in the right-click menu allows selecting a smarter ignore rule
    - Smart suggestions recognize common layouts so one rule can cover many files: clear out an app's `Contents/MacOS` subfolders while keeping the executables, skip every `node_modules` or build folder, skip the contents of a Photos or Final Cut library, drop a hidden config or secrets folder wherever it shows up
- **Reindex excluded path** appears in the results when a file you searched for is being hidden
    > It names the ignore rule or blocklist entry hiding the file and offers to lift it or add an exception, with no ignore syntax to write by hand
- **Per-scope ignore rules** for Applications, System, and the rest of the disk, editable in *Settings*
- **Respect each project's .gitignore**, an opt-in toggle in *Settings*
    > While indexing your Home folder, each project's own `.gitignore` and `.ignore` files are applied, so build output like `node_modules`, `target`, or `dist` drops out wherever it appears

## Fixes

- Dropping files into Finder with `⌥⏎` copies them instead of leaving aliases behind
- Installing the command-line tool checks its symlink and no longer overwrites a symlinked shell config

## Improvements

- **Volumes** settings moved into their own section
- App binaries are searchable by default
    > Indexing an app bundle keeps the executable in `Contents/MacOS` and the embedded framework binaries, while skipping the rest of the bundle's clutter
- Cleaner results out of the box across photo, video, audio, and developer tools
    > Default exclusions cover more cache and build junk: media caches (Adobe, Lightroom, Final Cut), dependency and build folders, simulator runtimes, device backups, and large machine-learning and virtual-machine files
- DEVONthink documents are searchable
    > Files kept inside DEVONthink databases, stored in a folder normally hidden from search, now show up in results
- **Reset to Default** on every ignore list and the blocklist, plus a single **Reset All to Default** that restores Cling's built-in rules everywhere at once

# 2.4.0

**[Download Cling 2.4.0 →](https://files.lowtechguys.com/releases/Cling-2.4.0.dmg)**
## Raycast extension

Cling's fuzzy search extension is now generally available in the Raycast store!

![raycast extension](https://files.lowtechguys.com/cling-raycast-extension-search.png)

## Features

- **Script Editor** in *Settings → Scripts*
    - Edit a script's code, name, and description in place, with create and delete built in
    - Configure how each script behaves (file types, file-count limits, confirmation, running once per file, output) with toggles instead of editing comment settings by hand
    - Each script has its own hotkey, pre-filled with an automatically assigned letter and changeable on the spot

![script editor](https://files.lowtechguys.com/cling-script-editor-setting-changelog.png)

- **File preview** panel alongside the results, on by default and toggled with `⌘⇧P`
    - Play and scrub video and audio, scroll PDFs, and pinch to zoom images, all inline
    - Text and code files are syntax highlighted with line numbers
    - Folders show their contents; archives and disk images (`.dmg`, `.iso`, `.zip`, `.rar`, and more) list their entries without unpacking or mounting
    - Select several files and step through their previews with the `← →` keys or the arrows in its header

![preview panel](https://files.lowtechguys.com/cling-preview-panel-changelog.png)

- **Search autocomplete** suggests a completion from your history as you type
    - `Tab` accepts it in full, `→` takes it one word at a time
    - `⌘↓` opens the full list of matching past searches

![suggestion hints](https://files.lowtechguys.com/cling-suggestions-hints.png)

## Improvements

- The Filter Editor is now reachable from *Settings → Filters* (previously it was only accessible by Option-clicking the filter button)
- The Settings window is resizable
- The show/hide hotkey can be set to Space, Return, Tab, or an arrow key, so combos like `⌥Space` work

# 2.3.2

**[Download Cling 2.3.2 →](https://files.lowtechguys.com/releases/Cling-2.3.2.dmg)**
## Fixes

- Return, arrows, tab and Esc are no longer intercepted while a CJK input method (Pinyin, Japanese, Korean, etc.) is composing text, so the IME can commit or navigate candidates as expected ([#25](https://github.com/alin23/Cling/issues/25))
- The *Search* placeholder hides while a CJK input method is composing so the marked pinyin/kana text is visible

# 2.3.1

**[Download Cling 2.3.1 →](https://files.lowtechguys.com/releases/Cling-2.3.1.dmg)**
## Improvements

- The right-click menu on results is now grouped by intent and implements some more useful actions:
    - **Open**, **Show in Finder**, **Quick Look**
    - **Open in Terminal**, **Edit in [Editor]**, **Open with Frontmost App**
    - **Rename**, **Duplicate**, **Compress** (zip)
    - **Copy** files to the pasteboard, plus the existing *Copy Paths*, *Copy Filenames* and *Export Results List* submenus
    - **Move to Trash**
- The *Hotkey* trigger key picker no longer shows `fn` and `caps lock` since they are not supported by the register hotkey API

# 2.3.0

**[Download Cling 2.3.0 →](https://files.lowtechguys.com/releases/Cling-2.3.0.dmg)**
## Features

- Press `⌥ Option - Enter` to have Cling automatically drag and drop selected files into the last focused field or window

<video controls src="https://files.lowtechguys.com/cling-drop-to-app.mp4" width="782" height="540"></video>

- New `depth:N` query operator caps results to entries at most *N* folders below the search root
    - Combine with a folder filter or `in:` token, e.g. `depth:1 in:~ .png` to find `~/Temp/cling.png` but exclude `~/Temp/subfolder/x.png`
    - Quick filters and Folder filters can now define a *Max depth* that's applied automatically when the filter is active
- Allow hiding specific action buttons from the interface in Settings

## Improvements

- The Filter Editor now has a hierarchical sidebar lets you jump straight to an individual filter
- New filters added with the *New Quick Filter* and *New Folder Filter* buttons now appear at the top of their section
- Hidden Cling window in *Instant Mode* no longer shows up in Mission Control
- Improved fuzzy scoring algorithm for path segments

# 2.2.0

**[Download Cling 2.2.0 →](https://files.lowtechguys.com/releases/Cling-2.2.0.dmg)**
## Features

- **Instant mode** keeps the main window alive in the background, so the hotkey brings it back without the usual launch and animation delay
    - Turn it off in *Settings → Window* if you prefer the old animated behavior
- **Remove disconnected volumes** from the cached index when you don't need them anymore
    - Can be found in the "Disconnected Volumes" section in *Settings → Volumes* and in the *Filter Editor*

## Improvements

- The window now opens noticeably faster after the first launch
- The OTP autofill bubble no longer pops over the search bar by explicitly opting out of the autofill heuristic controller introduced in macOS 26

## Fixes

- Typing in the Filter Editor no longer kicks focus out of the text field after every keystroke

# 2.1.3

**[Download Cling 2.1.3 →](https://files.lowtechguys.com/releases/Cling-2.1.3.dmg)**
## Improvements

- Search results now automatically refresh after **Apply & Reindex** or volume reindexing finishes
- Ignored files in volume `.fsignore` files are now properly excluded from the recents engine, both during reindex and live indexing

## Changes

- Time Machine backup volumes are no longer enabled for indexing by default

## Fixes

- **Apply & Reindex** now ensures the ignore file is saved to disk before starting the reindex

# 2.1.2

**[Download Cling 2.1.2 →](https://files.lowtechguys.com/releases/Cling-2.1.2.dmg)**
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

**[Download Cling 2.1.1 →](https://files.lowtechguys.com/releases/Cling-2.1.1.dmg)**
## Fixes

- `cling reindex --wait` actually waits for indexing to finish again
- Reindexing the **Home** scope no longer crashes when `/Users/Shared` is present
- Running `cling reindex` while another reindex is already in progress now gives a clear message instead of silently doing nothing

## CLI improvements

- `cling status --json` outputs structured status for scripting, including per-scope and per-volume progress
- `cling reindex --wait` shows live per-scope progress so you can tell exactly which scope is being worked on
- `cling reindex --scope <name> --wait` can safely attach to an in-progress reindex of that scope instead of hanging

# 2.1.0

**[Download Cling 2.1.0 →](https://files.lowtechguys.com/releases/Cling-2.1.0.dmg)**
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

**[Download Cling 2.0.1 →](https://files.lowtechguys.com/releases/Cling-2.0.1.dmg)**
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

**[Download Cling 2.0.0 →](https://files.lowtechguys.com/releases/Cling-2.0.0.dmg)**
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

# 1.2.2

**[Download Cling 1.2.2 →](https://files.lowtechguys.com/releases/Cling-1.2.2.dmg)**
## Improvements

- Update to fzf 0.64.0

## Fixes

- Fix Full Disk Access not being detected correctly when SIP is disabled
- Relaunch the app periodically every 12 hours to avoid search not working because of PTY leaks *(workaround until a proper fix is implemented)*

# 1.2.1

**[Download Cling 1.2.1 →](https://files.lowtechguys.com/releases/Cling-1.2.1.dmg)**
## Fixes

- Fix **Execute script** hotkey being shown as the wrong key

# 1.2

**[Download Cling 1.2 →](https://files.lowtechguys.com/releases/Cling-1.2.dmg)**
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

# 1.1

**[Download Cling 1.1 →](https://files.lowtechguys.com/releases/Cling-1.1.dmg)**
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

**[Download Cling 1.0 →](https://files.lowtechguys.com/releases/Cling-1.0.dmg)**
Initial release
