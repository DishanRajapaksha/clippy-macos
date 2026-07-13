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
- `make install-clippyctl` (installs the automation wrapper under `~/.local/bin` by default)
- `make clean`
- `make open` (opens `Clippy.xcodeproj` in Xcode)

## Automation

Clippy registers a `clippy://` URL scheme so scripts, CI jobs and personal automations can control the running app. Opening a URL launches Clippy when necessary.

```sh
open 'clippy://show'
open 'clippy://say?text=Build%20finished'
open 'clippy://animate'
open 'clippy://animate?name=Congratulate'
open 'clippy://agent?name=merlin'
```

The URL API supports:

- `clippy://show`
- `clippy://say?text=TEXT`
- `clippy://animate` for a random animation
- `clippy://animate?name=ANIMATION`
- `clippy://agent?name=AGENT`

Path values are accepted too, for example `clippy://agent/merlin`. Query values are safer for text containing spaces or punctuation.

### clippyctl

`scripts/clippyctl` is a small wrapper around the URL API. It handles URL encoding before calling macOS `open`.

```sh
make install-clippyctl

clippyctl show
clippyctl say "The deployment is complete"
clippyctl animate Congratulate
clippyctl agent merlin
```

Override the installation prefix when needed:

```sh
make install-clippyctl PREFIX=/usr/local
```

### macOS Shortcuts

After launching the app once, Clippy provides these App Intents in Shortcuts:

- Show Clippy
- Make Clippy Say
- Animate Clippy
- Select Clippy Agent

The same actions are available to Siri through the shortcut phrases macOS exposes for the app.

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
