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
git clone https://github.com/Cosmo/Clippy.git
cd clippy-macos
open Clippy.xcodeproj
```

Then build and run the **Clippy macOS** scheme in Xcode.

## Add Other Agents

This project uses extracted agent resources (it does not load `*.acs` directly).

1. Decompile an `*.acs` file using [MSAgent Decompiler](http://www.lebeausoftware.org/software/decompile.aspx).
2. Convert the extracted resources with this project’s script.
3. Move the generated `.agent` folder into the app’s Agents directory.

### Requirements

```sh
brew install imagemagick ffmpeg
```

### Convert

```sh
./agent-convert.sh PATH_TO_AGENT NEW_NAME
```

- `PATH_TO_AGENT`: path to the decompiled agent directory
- `NEW_NAME`: lowercase identifier for the generated bundle

Example:

```sh
./agent-convert.sh agents/CLIPPIT clippy
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
