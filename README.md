<img src="docs/icon.png" width="128" alt="DirectStat icon">

# DirectStat

A disk usage viewer for macOS: see which folders fill your disk and what is safe to delete.
Native SwiftUI + AppKit, no dependencies.

![DirectStat showing a folder tree sorted by size, cleanup suggestions, and a treemap](docs/screenshot.png)

## Why

When the disk is full, you need answers to two questions: *which folders are big*, and *what can I safely delete*.
DirectStat answers both in one window: a folder tree sorted by size, a treemap, and file types side by side,
plus a **Cleanup** list that recognizes caches and build output and says which are safe to delete.
It also shows how much used space no folder accounts for. Free, open source (MIT), and native on Apple Silicon
and Intel.

## Features

- **Folder tree** with a "% of parent" bar, size, item count and last-modified date.
  Click a column header to sort by name, size, items or date
- **Treemap** with cushion shading, colored by file type. Click to select, hover for path and size
- **Cleanup** tab: finds known space hogs (Xcode DerivedData, caches, `node_modules`,
  Docker image, Gradle/npm/Maven caches, iPhone backups, Trash…), labeled "Safe to delete" or "Review first"
- **Largest Files** and **File Types** tabs
- **Not in this scan**: on whole-disk scans, shows used space no folder accounts for (snapshots, system, no access)
- Move to Trash (Delete key) or delete permanently, with the tree and treemap updated in place.
  ⌘-click or ⇧-click to select several items and delete them in one go
- Fast parallel scanner (`getattrlistbulk`), sizes match `du` (allocated bytes, hard links counted once)
- **Private**: no network access at all. File names and sizes never leave your Mac

## Install

Requires macOS 15 or later.

1. Download the latest `DirectStat-x.y.z.dmg` from [Releases](../../releases), open it, and drag DirectStat onto
   the Applications folder.
2. Open DirectStat. The app isn't notarized, so the first launch is blocked: open
   **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
3. To scan every folder, turn on DirectStat in **System Settings › Privacy & Security › Full Disk Access**.

## Build and run

```sh
./scripts/build-app.sh          # creates build/DirectStat.app
open build/DirectStat.app
```

Requires macOS 15 and Xcode (or the Swift 6 toolchain).

To scan everything, add `build/DirectStat.app` in **System Settings › Privacy & Security › Full Disk Access**.
The app is ad-hoc signed, so macOS may ask again after a rebuild.

## Releasing

The `VERSION` file holds the version being developed: the next one to be released.

1. When the work is finished, tag that version and push. GitHub Actions checks that the tag matches
   `VERSION`, runs the tests, builds a universal (Apple Silicon + Intel) app, and publishes a release
   with `DirectStat-x.y.z.dmg` and its SHA-256:

   ```sh
   git tag "v$(cat VERSION)"
   git push origin main "v$(cat VERSION)"
   ```

2. Then set `VERSION` to the next version (for example `0.2.1` → `0.2.2`) and commit it, so
   development builds carry the new number.

To build the same disk image locally: `./scripts/package-release.sh` (output in `dist/`).

## Command line

```sh
swift run -c release directstat-cli ~ --top 10 --depth 2 --png treemap.png
```

Prints the largest folders, largest files, file types and cleanup suggestions.

## Layout

| Path | What |
|---|---|
| `Sources/DirectStatCore` | Scanner, tree model, treemap layout/renderer, cleanup rules |
| `Sources/DirectStat` | The Mac app (SwiftUI, with an `NSOutlineView` for the tree) |
| `Sources/directstat-cli` | Command-line version |
| `Tests/DirectStatCoreTests` | `swift test` |

Dev flags, debug builds only (`swift build`, then `.build/debug/DirectStat`): `--scan <path>` starts a scan on
launch; `--snapshot out.png --snapshot-after 10` saves a picture of the window and quits.

## License

MIT. See [LICENSE](LICENSE).
