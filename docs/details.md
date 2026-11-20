# Disk Inventory — details

English · [Русский](details.ru.md)

## Clean Up rules

| Group | What lands there |
|---|---|
| **Safe to Remove** | app caches, logs, the Trash (emptied in Finder) |
| **Rebuilt on Demand** | `node_modules`, `.build`, `target`, Python virtual environments next to a project file, npm/uv/pip/Gradle/Cargo caches, DerivedData, caches and logs in `/Library` |
| **Worth a Look** | installers in Downloads and on the Desktop, local AI models, simulator devices, Xcode archives, iPhone backups |
| **Not Opened Lately** | big files in Desktop, Documents, Downloads, Movies, Music, Pictures and iCloud Drive untouched for 3 months to 2 years; move them to iCloud Drive or Google Drive (“Archived from Mac”) or drop the local copy of iCloud files |

Build artifacts are not searched inside `~/Library`, hidden folders of the home folder and app bundles. Items the app lacks permission to move stay in place and appear under Details.

## Advice outside the home folder

`inventory_system` measures `/Library/Caches`, `/Library/Logs`, simulator caches, this user’s folders in `/private/var/folders`, `/private/tmp`, `/Users/Shared`, the Trash, simulator runtimes and devices, Homebrew, Docker, local Time Machine snapshots and the 60 biggest apps with days since their last launch.

An advice item is either

- **a path** the user can move to the Trash: caches, logs and temp files take any verdict; apps in `/Applications` and vendor folders in `/Library` only *review*; `/System`, `/usr`, `/opt/homebrew` and system configuration are refused;
- **an allowlisted action**: `brew-cleanup`, `brew-uninstall-cask`, `simctl-delete-unavailable`, `simctl-delete-device`, `simctl-runtime-delete`, `docker-prune`, `empty-trash`. The agent picks the action and its argument; the server checks that the cask, simulator or runtime exists and estimates the space. The row shows the exact command and a **Run…** button.

## Scanning

On APFS the walk is parallel: a shared folder queue, attributes read in batches with `getattrlistbulk`, partial scans merged with node renumbering, hard links and APFS clones counted once. Deleting a clone frees nothing while another copy exists, so cleanup sizes and the MCP report only what deleting would really free (`frees_if_deleted`). iCloud placeholders (dataless folders) are counted but never opened, so a scan downloads nothing.

| Folder | Entries | 1.5, one thread | 1.6, queue |
|---|---:|---:|---:|
| `Xcode.app/Contents/Developer` | 152,452 | 1.3–2.5 s | 1.0–1.6 s |
| a developer folder | 3.9 M | 121 s | 31 s |
| a whole home folder | 8.2 M | about an hour in 1.3 | 132 s |

## MCP tools

| Tool | What it does |
|---|---|
| `inventory_scan` | full scan of a folder or volume (`/System/Volumes/Data` for the boot volume), kept for 30 minutes |
| `inventory_children`, `inventory_top` | walk level by level; biggest files or folders anywhere below |
| `inventory_kinds`, `inventory_search` | space by file kind and search by name, kind or path. Search includes package contents by default. Set `packages: false` to treat packages as a single item. |
| `inventory_cleanup`, `inventory_stale` | the Clean Up rules; files not opened for months and cloud folders to move them to |
| `inventory_system` | what takes space outside the home folder, and the allowed actions |
| `inventory_advise`, `inventory_advice`, `inventory_advice_clear`, `inventory_show_cleanup` | send advice to the app, read what the user did, clear it, open the tab |
| `inventory_status` | protected-folder access, cloud folders, scans in memory |

Advice lives in `~/Library/Application Support/DiskAdvice/advice.json` and is announced with a distributed notification, so DiskSpot shows it too.

## Map, lists and settings

- Area is size. Big folders get a header with name and size. Tree, map and lists share one selection. Double-click or Return zooms in, ⌘↑ zooms out, arrows move between tiles, Space opens Quick Look.
- **Kinds** sums space by file type in the map’s colors; picking a kind highlights its tiles. **Largest Files** lists files by size; the toolbar search filters by name, kind or folder.
- **View** switches size on disk / logical size, package contents, free and other space.
- **Settings (⌘,)**: four map palettes, labels, folder borders, panel layout; scanning options; zoom animation, Finder sync, Trash confirmation.

## Tests

```sh
swift test
```

```sh
binary="dist/Disk Inventory.app/Contents/MacOS/DiskInventory"
"$binary" --smoke-test /path/to/folder
"$binary" --layout-smoke-test /path/to/folder
"$binary" --settings-smoke-test /path/to/folder
"$binary" --trash-smoke-test
```

`Scripts/screenshots.sh` rebuilds the README screenshots from a synthetic home folder (`Scripts/demo-home.py`), so they never show real files.

[Notes on the original Disk Inventory X 1.3 (in Russian)](../Research/analysis.md)
