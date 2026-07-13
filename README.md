# Clippy for macOS

Clippy is a native macOS menu bar app that runs classic Microsoft Agent characters.

## Controls

- Drag with mouse: move Clippy
- Right-click on Clippy: `Animate!`
- Space bar: animate
- Double-click: animate
- Menu bar (`📎`):
  - `Show` / `Hide`
  - `Agents`
  - `Auto Animate` interval (or Off)
  - `Mute`
  - `Behavior` → `App Visibility`:
    - Toggle `Hide in <foreground app>` to add or remove a per-app rule
    - Select a saved application to remove its rule, or use `Clear All`
    - Clippy hides when a configured app becomes active and returns without stealing focus when you leave it
  - `Reload`

## Build and Run

```sh
git clone https://github.com/DishanRajapaksha/clippy-macos.git
cd clippy-macos
make build
make run
```

Useful targets:

- `make help`
- `make build`
- `make run`
- `make package` (creates a Release zip under `dist/`)
- `make clean`
- `make open` (opens `clippy.xcodeproj` in Xcode)

## Publish Binaries

GitHub Actions publishes unsigned macOS binaries from `.github/workflows/publish-binaries.yml`.

- Run `Publish Binaries` manually to produce a downloadable workflow artifact.
- Push a version tag such as `0.1.0` to create a GitHub release with `Clippy.app` zipped under `dist/`.

Local package build:

```sh
make package
```

## Add Other Agents

The app can import Microsoft Agent `*.acs` files directly.

1. Click `📎` in the menu bar.
2. Choose `Import Agent…`.
3. Select one or more `*.acs`, `*.agent`, or `*.agent.zip` files.
4. Select the imported character under `📎` → `Agents`.

The older extracted-resource flow is still available if you already have a decompiled agent directory.

### Requirements

```sh
brew install imagemagick ffmpeg
```

### Convert

```sh
make convert-agent AGENT_PATH=PATH_TO_AGENT NEW_NAME=NEW_NAME
```

- `PATH_TO_AGENT`: path to the decompiled agent directory
- `NEW_NAME`: lowercase identifier for the generated bundle

Example:

```sh
make convert-agent AGENT_PATH=agents/CLIPPIT NEW_NAME=clippy
```

### Install Converted Agent

1. Click `📎` in the menu bar.
2. Choose `Show in Finder`.
3. Move `NEW_NAME.agent` into the Agents directory.
4. Click `📎` → `Reload`.
5. Select the new agent under `📎` → `Agents`.

## Attributions

- Original macOS app: Devran "Cosmo" Uenal ([`@maccosmo`](http://twitter.com/maccosmo))
- Inspiration:
  - <https://github.com/tanathos/ClippyVS> (C#)
  - <https://github.com/smore-inc/clippy.js> (JavaScript)
- Character/IP attribution: Microsoft
