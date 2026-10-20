# SpaceUtilizer

A native **macOS app that shows what each application really costs in disk space**, and removes it
completely, including the models, caches and data it keeps outside the `.app` bundle.

## Features
- Disk overview for Macintosh HD.
- Scans `/Applications` and `~/Applications`, sorted by total footprint.
- For every app it finds:
  - **Library files:** Preferences, Caches, Application Support, Logs, Containers, Group Containers,
    HTTPStorages/WebKit, Saved State and Launch Agents.
  - **Data & models stored elsewhere**, e.g. `~/.ollama`, `~/.lmstudio`, Docker VM images, Xcode
    DerivedData and simulators, Android emulators, Steam games, plus any `~/.<appname>` folder.
- **Uninstall Completely:** one sheet with a checkbox for every item, grouped as:
  - *App Data & Models* — selected by default (useless once the app is gone)
  - *Your Content* — recordings, archives, synced folders; **not** selected by default
  - *Shared Libraries & SDKs* — Android SDK, Gradle cache, Homebrew Cellar; **not** selected by default
  - Python/Node/Rust/etc. toolchain folders (`~/.pyenv`, `~/.npm`, `~/.cargo`, …) are never matched.
- **Checks what else uses the files.** Before deleting, it looks for other apps that share the folder,
  apps known to use the same models (e.g. Msty or Enchanted with Ollama), your projects that import the app or point
  at the folder, symlinks into it, and programs that have files open there. Anything in use gets an
  **In use** warning and is unticked by default.
- **Three removal options for apps:** App Only · Keep Models & Data · Uninstall Completely.
- **Projects:** lists the projects in your project folders (default `~/Documents/Projects_Folder`, add more with **+**).
  For each project it shows source code, build files (node_modules, venvs, .build, DerivedData), models & data
  (even nested ones), the installed copy of the app, and git status (uncommitted or unpushed work).
  Options: Clean Build Files · Delete, Keep Models & Data · Delete Completely.
- Everything goes to the **Trash**, so it can be restored until you empty it.
- File Browser window (⌘B) to explore any folder by size.

## Build & install
Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
bash build_app.sh            # → dist/SpaceUtilizer.app and dist/SpaceUtilizer.dmg
bash build_app.sh --install  # also installs into /Applications and opens it
```

The DMG can be used to install on other Macs. The app is ad-hoc signed, so the first time
on another Mac, right-click it and choose **Open**.

### Recommended permission
To see and remove sandboxed app data in `~/Library/Containers`, give SpaceUtilizer
**Full Disk Access**: System Settings › Privacy & Security › Full Disk Access › **+** › SpaceUtilizer.

## Development
```bash
swift build
swift run SpaceUtilizer
```
