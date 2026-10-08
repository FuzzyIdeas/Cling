#!/usr/bin/env python3
"""Keep the MCP settings bridge honest about what Cling actually has.

The bridge in Cling/MCPSettings.swift is hand-maintained, and nothing in the compiler notices when it
drifts: a new toggle in a Settings pane gets no key an agent can read or write, and a renamed key leaves
a registry entry pointing at nothing. Either way an agent confidently reports a setting that is not
there, or cannot find the one that is.

    Scripts/settings-index-audit.py            # errors only, exit 1 on drift
    Scripts/settings-index-audit.py --coverage # plus which defined keys are not exposed, and why

Errors (exit 1):
  - the registry names a key that no `Defaults.Keys` extension defines
  - a registry entry's name differs from the key it reads, so an agent's key is not the app's
  - a key bound with @Default in a Settings pane is neither in the registry nor listed below with a reason
  - two registry entries share a name
  - a top-level CLI command has no MCP tool and is not listed below with a reason

Cling has no settings search index the way Clop has, so the titles live in the registry itself and
there is nothing else to cross-check.
"""
import argparse
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

# Settings files whose @Default bindings are what the user can change on screen.
PANE_FILES = [
    "Cling/SettingsView.swift",
    "Cling/ShortcutsSettingsPane.swift",
    "Cling/MCPSettingsPane.swift",
    "Cling/InterfacePicker.swift",
    "Cling/Filters.swift",
    "Cling/ScriptPickerView.swift",
    "Cling/WebAccess/WebAccessSettingsPane.swift",
]

# Keys a pane binds that the bridge deliberately does not take, and where they go instead.
HANDLED_ELSEWHERE = {
    "searchScopes": "cling_scopes, which refuses the Pro scopes without a licence",
    "disabledVolumes": "cling_volumes",
    "disabledCloudLocations": "cling_cloud",
    "reindexTimeIntervalPerVolume": "cling_volumes interval",
    "unfollowedVolumes": "cling_volumes follow and unfollow",
    "blockedPrefixes": "cling_ignore, target blocklist-prefix",
    "blockedContains": "cling_ignore, target blocklist-contains",
    "quickFilters": "cling_filter_write and cling_filter_delete",
    "folderFilters": "cling_filter_write and cling_filter_delete",
}

NOT_EXPOSED = {
    "mcpEnabled": "the agent switch; an agent reads it through cling_status and only the user turns it on",
    "searchHintsManuallyEnabled": "bookkeeping, set alongside showSearchHints",
    "searchBarPillOrigin": "where the pinned search field sits, set by dragging it; the Style preview only shows it",
    "webAccessPort": "where the web server listens; only the user moves it, alongside the switch",
    "webAccessKey": "the key that signs a browser in to this Mac's files; it never goes to an agent",
    "webAccessLinkHost": "which address or name the pairing link and QR code carry, picked beside them",
}

# Top-level CLI commands with no MCP tool.
CLI_WITHOUT_TOOL = {
    "recents": "the Recent Files list; an agent has no use for it that cling_search does not cover",
    "logs": "covered by cling_debug_logs, which asks for root with a dialog instead of sudo",
    "catch-up": "run by the launch agent while Cling is closed",
    "mcp": "the server itself; cling_status reads mcp status",
}


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    src = re.sub(r"/\*[\s\S]*?\*/", "", src)
    return re.sub(r"^\s*//.*$", "", src, flags=re.M)


def swift_files(folder):
    for dirpath, _, names in os.walk(os.path.join(ROOT, folder)):
        for name in names:
            if name.endswith(".swift"):
                yield os.path.relpath(os.path.join(dirpath, name), ROOT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coverage", action="store_true")
    args = ap.parse_args()

    defined = {}
    for rel in swift_files("Cling"):
        for ident, name in re.findall(r'static let (\w+) = Key<.+?>\("([^"]+)"', strip_comments(read(rel))):
            defined[ident] = name

    registry = strip_comments(read("Cling/MCPSettings.swift"))
    keys_block = registry[registry.index("static let keys:"):registry.index("static var keysByName")]
    # bool("name", .key, ...) and the other builders that take a Defaults key.
    typed = re.findall(r'\b(?:bool|int|double|presets|duration|rawValue|app|readOnly)\(\s*"(\w+)",\s*\.(\w+)', keys_block)
    # Builders for keys that need their own parsing name the key inside.
    custom = re.findall(r'MCPSettingKey\(name: "(\w+)"', registry)
    custom_keys = {"launchAtLogin": None, "showAppKey": "showAppKey", "triggerKeys": "triggerKeys",
                   "barActions": "barActions", "hiddenActions": "hiddenActions"}

    errors = []
    names = [n for n, _ in typed] + [n for n in custom if n in custom_keys]
    for n in sorted({n for n in names if names.count(n) > 1}):
        errors.append(f"two registry entries are named {n!r}")

    registered = set()
    for name, key in typed:
        if key not in defined:
            errors.append(f"registry entry {name!r} reads .{key}, which no Defaults.Keys extension defines")
        if name != key:
            errors.append(f"registry entry {name!r} reads .{key}; an agent's key should be the app's")
        registered.add(key)
    for name in custom:
        if name not in custom_keys:
            continue
        key = custom_keys[name]
        if key is None:
            continue
        if key not in defined:
            errors.append(f"registry entry {name!r} reads .{key}, which no Defaults.Keys extension defines")
        registered.add(key)

    bound = set()
    for rel in PANE_FILES:
        bound |= set(re.findall(r"@Default\(\.(\w+)\)", strip_comments(read(rel))))
    for key in sorted(bound - registered - set(HANDLED_ELSEWHERE) - set(NOT_EXPOSED)):
        errors.append(f"Settings binds .{key}, which the MCP registry neither exposes nor lists with a reason")

    warnings = []
    for key in sorted((set(HANDLED_ELSEWHERE) | set(NOT_EXPOSED)) - set(defined)):
        warnings.append(f"{key!r} is listed in this script but no longer defined")

    # Every CLI command reaches agents too.
    cli = read("ClingCLI/ClingCLI.swift")
    sub_block = cli[cli.index("subcommands: ["):]
    sub_block = sub_block[:sub_block.index("]")]
    types = re.findall(r"(\w+)\.self", sub_block)
    table = read("ClingCLI/MCPToolTable.swift")
    for t in types:
        # The naming the commands follow: `FilterCommand` is `cling filter`, `CatchUp` is `cling catch-up`.
        command = t[: -len("Command")].lower() if t.endswith("Command") else re.sub(r"(?<!^)(?=[A-Z])", "-", t).lower()
        if command in CLI_WITHOUT_TOOL:
            continue
        if f'["{command}"' not in table:
            errors.append(f"cling {command} has no MCP tool in MCPToolTable.swift and no reason listed here")

    print(f"{len(defined)} keys defined, {len(registered)} exposed through MCP, {len(bound)} bound in Settings panes")

    if args.coverage:
        rest = sorted(set(defined) - registered - set(HANDLED_ELSEWHERE) - set(NOT_EXPOSED))
        print(f"\nhandled by their own tools: {', '.join(sorted(HANDLED_ELSEWHERE))}")
        print(f"\n{len(rest)} defined keys with no row in Settings and no MCP entry (state, history, geometry):")
        for k in rest:
            print(f"  {k}")

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)

    if errors:
        print(f"\n{len(errors)} problem(s):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    print("no drift")
    return 0


if __name__ == "__main__":
    sys.exit(main())
