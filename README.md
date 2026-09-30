# DiskScope

[English](README.md) · [简体中文](README.zh-CN.md) · [MIT License](LICENSE)

DiskScope is a local macOS disk analyzer and cleanup app. Explore storage with a nested treemap, find large files and development caches, review app-related files, and watch live system metrics.

Built with Swift, AppKit, and a local WebKit interface. All implemented features are available without an account or paid license. The app has no analytics, cloud backend, or network service; scanning and cleanup run on your Mac.

## Features

| Area | What you can do |
| --- | --- |
| Storage scanning | Scan your home folder, the startup volume, or a chosen folder; select external volumes separately |
| Interactive treemap | Select files, enter folders, navigate breadcrumbs, and open context menus |
| File browsing | Switch between treemap, paginated file list, and largest files |
| Search | Search the current scan, or use Spotlight for Home / Full Mac searches |
| Development filters | Find Node.js, Xcode, build artifacts, Android, Docker, virtual machines, caches, AI models, and more |
| Cleanup queue | Review selected paths and move items to Finder's Trash with native confirmation |
| App cleanup | Inspect installed apps, select related files, and review leftover candidates |
| System monitor | CPU, memory, compression, swap, physical network interfaces, battery, and top processes; refreshes every two seconds |
| Appearance | Six local themes, consistent file-type colors, and a draggable native window header |
| Reports | Export scan metadata to CSV |
| Shortcuts | ⌘F to search; ⌘Q to quit |

## Build and run

Requirements:

- macOS 13 or later.
- Xcode Command Line Tools (`xcode-select --install` if not already installed).
- No Electron, Node.js, or Python runtime is needed to run the app. Python 3 and Node.js are used only for tests.

```sh
git clone https://github.com/amtbsl/DiskScope.git
cd DiskScope
zsh scripts/build.sh
open build/DiskScope.app
```

The build targets the architecture of your Mac. Development and manual validation have been performed on an Apple Silicon Mac with macOS; Intel builds have not been verified. The build script applies an ad hoc signature and generates the app icon from source. Builds are not Apple-notarized.

To install or update your locally built copy, quit DiskScope first:

```sh
zsh scripts/install.sh
open /Applications/DiskScope.app
```

The installer preserves a previous DiskScope build under `build/` and refuses to replace an unrelated app with the same name.

## Using DiskScope

1. Start with **Scan Home** or **Choose Folder**. Choose an external volume to scan it separately.
2. Single-click a treemap item to select it; double-click a folder to enter it. Use **List** or **Large Files** for a tabular view.
3. Search or select filters to narrow the results. **Current Scan** uses the scan database; **Home** and **Full Mac** search the system's Spotlight index.
4. Use **Reveal**, **Open**, **Copy Path**, or **Add to Queue** to inspect and organize selected items. Review the native confirmation before moving anything to Trash.
5. Open **Apps** to inspect installed applications and related files. Leftover candidates are unchecked by default.
6. Drag empty space in the top toolbar to move the window. Search-field text remains selectable; ordinary interface labels do not select when dragged.

## Permissions and limitations

- Ordinary folders can be scanned immediately. Protected locations such as Mail, some containers, and Trash may require **System Settings → Privacy & Security → Full Disk Access**. Enable the installed DiskScope app and restart it. DiskScope does not grant itself permissions.
- Inaccessible paths are counted and displayed. A skipped location does not mean it contains no data.
- File sizes use allocated blocks (`st_blocks × 512`) and also retain logical sizes. Hard links are deduplicated by inode; symlinks are not followed. APFS clones, snapshots, and purgeable space prevent exact reconciliation with volume-level storage totals.
- Startup-volume scans skip duplicate `/System/Volumes` mounts, device nodes, and external volumes. Scan external storage separately.
- A single background scanner retains up to two million entries and a maximum directory depth of 256. Reaching a limit produces a **Partial scan** notice; select a smaller folder to continue.
- The treemap sends a bounded hierarchy to the interface and groups omitted small entries under **Other**. File lists have 400 entries per page; searches return at most 500 results.
- Spotlight results depend on the system index. A directory's Spotlight size is not its recursive content size.
- Related-file and leftover detection is heuristic. Shared app groups and leftover candidates are not automatically selected. Inspect paths before cleanup; custom locations and helper tools may be missed.
- Normal cleanup uses Finder's recoverable Trash without `sudo`. Protected system paths, top-level personal folders, running apps, and DiskScope itself cannot be queued for removal. **Empty Trash** permanently deletes only this user's `~/.Trash` after a typed `EMPTY` confirmation.
- Memory metrics are Mach VM estimates in GiB/MiB. Process CPU comes from macOS `ps` and can exceed 100% for multi-core workloads. Network metrics use physical `en*` interfaces and exclude VPN tunnels.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Sources/Core.swift` | POSIX scanner, file types, filters, queue normalization, protected paths |
| `Sources/Services.swift` | Storage and system metrics, app discovery, related files and leftovers |
| `Sources/main.swift` | Native window and drag handling, WebKit bridge, file dialogs and cleanup review |
| `web/` | Local HTML/CSS/JavaScript interface and squarified treemap layout |
| `scripts/` | Build, install, original app icon generation, and test runner |
| `tests/` | Scanner and treemap regression tests |
| `docs/VALIDATION.md` | Development validation notes in Chinese |

## Validation

With Python 3 and Node.js installed:

```sh
zsh scripts/test.sh
```

This builds the app, runs scanner and treemap regressions, checks JavaScript syntax, samples real system metrics, and exercises a reversible Trash round trip with a newly created UUID-named test file. It does not delete existing personal files. See [validation notes](docs/VALIDATION.md) for manual checks and unverified cases.

## Project origin

DiskScope is an independent implementation inspired by the observable interface and publicly described functionality of [DissectMac](https://dissectmac.com/). It does not include DissectMac source code or assets, modify the original app, or change its license checks. DiskScope is not affiliated with or endorsed by DissectMac. The MIT license applies to the code and assets in this repository, not to the referenced third-party product.

## License

Copyright © 2026 amtbsl. Released under the [MIT License](LICENSE).
