# Sweep

A native macOS cleaner in the spirit of CleanMyMac X, built with SwiftUI.

## What it does

| Screen | What it does |
| --- | --- |
| **Smart Scan** | Runs Cleanup, Protection and Speed together, shows a summary, and cleans everything you leave ticked in one go. |
| **System Junk** | Finds user caches, user and system logs, and Xcode build leftovers (DerivedData, device support, simulator caches). |
| **Large & Old Files** | Lists files over 100 MB in Desktop, Documents, Downloads, Movies, Music and Pictures, with filters by size, age and kind. |
| **Trash Bins** | Shows how much space the Trash uses and empties it through Finder. |
| **Privacy** | Clears history, caches, sessions, cookies and form data for Chrome, Edge, Brave, Firefox and Safari, plus recent-items lists. Saved passwords and bookmarks are never touched. |
| **Optimization** | Live memory, CPU and disk figures, frees inactive memory, flushes the DNS cache, lists the apps using the most memory, and links to Login Items. |
| **Uninstaller** | Lists your apps with their real size and last-opened date, removes an app with its support files, caches, preferences, containers and launch agents, and finds leftovers from apps you've already deleted. |

Malware Removal, Maintenance and Updater appear in the sidebar as "coming soon".

### Safety

- Everything Sweep removes is **moved to the Trash**, never deleted outright, so you can put it back from Finder. Only "Empty Trash" is permanent, and it asks first.
- Browsers are skipped while they're open, because they rewrite their files when they quit.
- Freeing memory and flushing DNS use the standard macOS administrator prompt.
- Safari, Messages and the Trash are protected by macOS. Give Sweep **Full Disk Access** in System Settings › Privacy & Security to clean them.

## Requirements

macOS 13 Ventura or later, and Xcode 15 or later (Swift 5.9).

## Build and run

```sh
# Run straight from the package
swift run Sweep

# Or build a double-clickable app into ./build/Sweep.app
scripts/build-app.sh
open build/Sweep.app
```

You can also open `Package.swift` in Xcode and run the **Sweep** scheme.

Run the tests with `swift test`.

## Project layout

```
Sources/SweepCore/   Scanning and cleaning logic, no UI (unit tested)
Sources/Sweep/       SwiftUI app: models per screen, views, theme
Tests/               Tests for SweepCore against temporary folders
Resources/Info.plist App bundle metadata used by scripts/build-app.sh
Resources/AppIcon.svg Source artwork for the app icon (broom on graphite)
Resources/AppIcon.icns App icon built from AppIcon.svg, copied in by scripts/build-app.sh
```
