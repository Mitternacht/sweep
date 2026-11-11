# Sweep

A small Mac app that shows what's eating your disk, explains each thing in plain words, and deletes the stuff that is safe to delete.

## What it does

- **Clean Up** lists things Sweep understands and groups them by how safe they are:
  - **Safe to clean** rebuilds or downloads again by itself (Xcode build output, package caches, app caches, `node_modules`, the Trash).
  - **Review first** is probably stale but only you can tell (simulators, Xcode archives and test results, old installers, iPhone backups, temp folders). Sent to the Trash by default.
  - **Protected** is never touched (see below).
- Every item says what it is, where it lives, what's inside it, how old it is and what happens if you delete it. The inspector on the right shows the details.
- **Explore** shows any drive folder by folder, as a list or a map, with plain-language notes and a lock on protected folders.
- Works on every drive you plug in. Build junk on external drives (for example Xcode's DerivedData if you moved it there) is found too.
- After a cleanup it shows how much space really came back, measured from the drive's free space, not from file sizes.

## Safety

Every delete goes through one guard (`DeletionGuard` in `Core/PathSafety.swift`) that refuses anything that is:

- outside the folder the cleanup rule is allowed to touch, or not named what the rule expects (`node_modules`, `.xcresult`, ...)
- a drive, your home folder, or too close to the top of a disk
- a Git repository
- on the protected list: Claude Code and Codex history, your Documents, Desktop, Pictures, Movies and Music, iCloud Drive, Mail, Messages, Safari, keychains, SSH/GPG keys, signing profiles, Xcode settings, apps and macOS itself
- inside or above something protected

It also refuses to clean things an open app is using ("Quit Xcode first", "In use by Cursor"). Symlinks are removed as links, never followed. 42 tests cover the guard, the scanner and the cleaner.

## Running it

Open `Sweep.xcodeproj` in Xcode and run, or install the Release build:

```bash
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration Release -destination 'platform=macOS' -derivedDataPath build build
ditto build/Build/Products/Release/Sweep.app ~/Applications/Sweep.app
```

Give it **Full Disk Access** (System Settings > Privacy & Security) so it can see the Trash and iPhone backups. The app has a button that opens that page.

Sweep isn't sandboxed (it has to scan and delete across the whole disk) and is signed ad hoc for local use.

## Layout

```
Sweep/Core      scanning, rules, safety guard, cleaner (no UI)
Sweep/Model     AppModel and ExplorerModel (@Observable)
Sweep/Views     SwiftUI screens
SweepTests      Swift Testing
```

To teach Sweep a new kind of space, add a `Rule` in `Core/Catalog.swift`: where to look, how safe it is, what it is and what happens if it goes.
