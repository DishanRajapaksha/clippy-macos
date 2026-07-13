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
- `make install-clippyctl` (installs the automation wrapper under `~/.local/bin` by default)
- `make clean`
- `make open` (opens `Clippy.xcodeproj` in Xcode)

## Automation

Clippy registers a `clippy://` URL scheme so scripts, CI jobs and personal automations can control the app. Opening a URL launches Clippy when necessary.

### URL API

| Action | URL |
|---|---|
| Show | `clippy://show` |
| Hide | `clippy://hide` |
| Toggle visibility | `clippy://toggle` |
| Say text | `clippy://say?text=TEXT` |
| Random animation | `clippy://animate` |
| Named animation | `clippy://animate?name=ANIMATION` |
| Stop animation, audio and automation speech | `clippy://stop` |
| Select an agent | `clippy://agent?name=AGENT` |
| Select a random agent | `clippy://random-agent` |
| Reload agent and animation menus | `clippy://reload` |
| Set mute | `clippy://mute?enabled=true` |
| Set click-triggered speech bubbles | `clippy://bubbles?enabled=false` |
| Set always-on-top | `clippy://always-on-top?enabled=true` |
| Set all-Spaces behaviour | `clippy://all-spaces?enabled=true` |
| Move to a named position | `clippy://position?name=bottom-right` |
| Move to absolute AppKit coordinates | `clippy://move?x=120&y=80` |
| Disable auto-animation | `clippy://auto-animate?value=off` |
| Use random auto-animation intervals | `clippy://auto-animate?value=random` |
| Set auto-animation interval | `clippy://auto-animate?seconds=30` |

Boolean values accept `true`/`false`, `on`/`off`, `yes`/`no`, and `1`/`0`. Named positions are `top-left`, `top-right`, `bottom-left`, `bottom-right`, and `center`; `centre` is accepted as an alias. Auto-animation intervals must be between 5 and 3,600 seconds.

Path values are accepted where one value is needed. For example:

```sh
open 'clippy://agent/merlin'
open 'clippy://position/centre'
open 'clippy://mute/off'
```

Query values are safer for text containing spaces or punctuation.

### clippyctl

`scripts/clippyctl` is a small wrapper around the URL API. It handles URL encoding before calling macOS `open`.

```sh
make install-clippyctl

clippyctl show
clippyctl hide
clippyctl toggle
clippyctl say "The deployment is complete"
clippyctl animate Congratulate
clippyctl stop
clippyctl agent merlin
clippyctl random-agent
clippyctl mute on
clippyctl bubbles off
clippyctl always-on-top on
clippyctl all-spaces off
clippyctl position bottom-right
clippyctl move 120 80
clippyctl auto-animate random
clippyctl auto-animate 30
```

Override the installation prefix when needed:

```sh
make install-clippyctl PREFIX=/usr/local
```

### macOS Shortcuts

After launching the app once, Clippy provides Shortcuts actions for:

- Visibility: show, hide and toggle
- Speech, animation and stopping playback
- Selecting a named or random agent
- Mute, speech-bubble, always-on-top and all-Spaces settings
- Named positioning and absolute movement
- Auto-animation configuration

Common actions also expose Siri shortcut phrases through macOS.

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
