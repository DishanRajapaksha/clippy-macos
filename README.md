# Clippy for macOS

Clippy is a native macOS menu bar app that runs classic Microsoft Agent characters.

## Controls

- Drag with mouse: move the selected agent
- Right-click an agent: open controls for that window
- Space bar: animate the selected agent
- Double-click: animate
- Menu bar (`📎`):
  - `Show Current` / `Hide Current`
  - `Show All` / `Hide All`
  - `New Agent`: open another independent character window
  - `Agent Windows`: select and bring forward a running character
  - `Agent Manager…`: open a table of every running session with per-agent controls
  - `Close Current Agent`
  - `Change Current Agent`
  - `Auto Animate` interval or Off
  - `Mute Current`
  - `Speech Bubbles`
  - `Behavior`: per-agent Always on Top, Join All Spaces, Throw Inertia, Edge Snap, and Paired Reactions
  - `Reload`

The Agent Manager window shows each session's active state, character, visibility, mute state, auto-animation interval, paired-reaction setting, current position and display. It also supports focusing or closing individual agents and creating, showing or hiding sessions in bulk.

Each agent window keeps its own character, position, mute state, speech preference, animation interval, window behaviour, and paired-reaction preference. Sessions are restored the next time Clippy launches.

When Paired Reactions are enabled for both characters, agents greet and react once when their windows approach one another. They become eligible for another reaction after moving apart.

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
4. Select the imported character under `📎` → `Change Current Agent` or create it from `New Agent`.

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
5. Select the new agent under `📎` → `Change Current Agent` or `New Agent`.

## Attributions

- Original macOS app: Devran "Cosmo" Uenal ([`@maccosmo`](http://twitter.com/maccosmo))
- Inspiration:
  - <https://github.com/tanathos/ClippyVS> (C#)
  - <https://github.com/smore-inc/clippy.js> (JavaScript)
- Character/IP attribution: Microsoft
