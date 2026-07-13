# Multiple Agents

Clippy can run two or more independent Microsoft Agent characters at the same time. Each session owns its own window, controller, playback lifecycle and persisted settings.

## Session controls

Use the menu bar (`📎`) to:

- show or hide the current agent
- show or hide every agent
- create a named or random agent
- switch between running agent windows
- close the current agent
- change the current character
- configure per-agent mute, speech bubbles, auto-animation and behaviour

Each session persists its character, position, mute state, speech preference, animation interval, always-on-top state, Spaces behaviour, throw inertia, edge snapping and paired-reaction setting.

## Agent Manager

Open `📎` → `Agent Manager…` for a table of all running sessions. It provides:

- active-agent selection
- character selection
- visibility and mute toggles
- auto-animation interval
- paired-reaction toggle
- current coordinates and display
- focus and close actions
- bulk create, show and hide controls
- a shortcut to Resource Monitor

The manager window restores its previous size and position.

## Resource Monitor

Open `📎` → `Resource Monitor…` to inspect live resource use. Sampling runs once per second only while the window is open, and the timer stops when the monitor closes. Hidden agents remain listed so their retained resources are still visible.

App-wide measurements:

- process CPU usage
- resident memory
- total estimated texture-cache size
- aggregate agent FPS

Per-agent measurements:

- current status and animation
- estimated animation-preparation work
- estimated decoded texture-cache size
- rendered-frame total
- frames presented during the previous one-second window
- active speech depth

Process CPU and resident memory are actual process measurements. Per-agent work and texture cache are estimates because every character runs inside the same macOS process.

## Arrange Agents

Use `📎` → `Arrange Agents` to:

- move the current agent to the cursor once
- toggle `Follow Current to Cursor` for the active agent
- stop every cursor-following agent
- move every agent to a selected display
- scatter agents
- stack agents
- arrange agents in a horizontal line
- arrange agents in a grid
- arrange agents in a circle

Follow Cursor is stored per session and restored after relaunch. The character trails just below and to the right of the pointer with smoothed movement. Multiple followers form a small diagonal procession instead of occupying exactly the same point. Clicking and dragging a follower disables the mode for that agent, while applying a desktop layout disables it for all affected agents.

Layouts use the display under the pointer by default. Every resulting window is clamped to the target display's visible frame and its position is persisted.

## Paired reactions

When Paired Reactions are enabled for both characters, agents greet and react once when their windows approach. They become eligible for another exchange after moving apart.

## App visibility

The shared `Behavior` → `App Visibility` rules apply to every agent window. When a configured application becomes active, all affected character windows disappear and return without taking keyboard focus when the user leaves that application.
