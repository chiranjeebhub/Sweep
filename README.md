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
| **Malware Removal** | Checks launch agents, launch daemons, apps and support folders for known Mac adware families, startup items that run from hidden or temporary folders, and unsigned programs that start on their own. Stops and removes what you tick. It complements XProtect, which macOS keeps updated in the background. |
| **Optimization** | Live memory, CPU and disk figures, frees inactive memory, flushes the DNS cache, lists the apps using the most memory, and links to Login Items. |
| **Maintenance** | Runs maintenance scripts, rebuilds Launch Services, clears the Quick Look and font caches, reindexes Spotlight, thins Time Machine local snapshots and verifies the startup disk. |
| **Uninstaller** | Lists your apps with their real size and last-opened date, removes an app with its support files, caches, preferences, containers and launch agents, and finds leftovers from apps you've already deleted. |
| **Updater** | Checks App Store apps against the App Store and other apps against their Sparkle update feed. Sparkle updates are downloaded and installed in place after checking they're signed by the same developer. App Store updates open in the App Store. |

### Safety

- Everything Sweep removes is **moved to the Trash**, never deleted outright, so you can put it back from Finder. Only "Empty Trash" is permanent, and it asks first.
- Browsers are skipped while they're open, because they rewrite their files when they quit.
- Freeing memory, flushing DNS, some Maintenance tasks and removing malware outside your home folder use the standard macOS administrator prompt.
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
