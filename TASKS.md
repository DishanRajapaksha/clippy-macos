# Clippy Improvement Tasks

## Animation Behavior

- [x] Prevent animation overlap.
  - Track whether an animation is currently running.
  - Do not let idle animations interrupt explicit user actions such as show, hide, keyboard, or double-click animations.
  - Decide whether explicit animations should interrupt idle animations or queue after them.

- [x] Add randomized idle timing.
  - Keep idle behavior simple: run idle animations from time to time without cursor or app-focus detection.
  - Replace the fixed timer cadence with a randomized interval range, for example 10 to 25 seconds.
  - Keep the existing Auto Animate menu controls working.

## Interaction

- [x] Improve the right-click menu.
  - Add actions for Idle Animation, Say Something, Change Agent, and Hide.
  - Consider listing common animations from the currently loaded agent.

- [x] Add app behavior options.
  - Launch at login.
  - Always on top.
  - Join all Spaces.
  - Enable or disable throw inertia.
  - Enable or disable edge snap.

- [x] Persist Clippy position.
  - Save the last window position after drag or snap.
  - Restore the saved position on launch.
  - Clamp the restored position to the current visible screen.

## Speech Bubbles

- [x] Improve speech bubble rendering.
  - Use parsed `AgentBalloon` styling where possible.
  - Add a speech-tail pointer.
  - Size the bubble based on text.
  - Place the bubble so it stays on-screen.

- [x] Expand speech bubble interactions.
  - Add more phrases.
  - Allow menu-triggered speech.
  - Consider pairing some phrases with matching animations.

## Agent Management

- [x] Polish agent import feedback.
  - Report successful imports.
  - Report failed imports with useful error text.
  - Refresh the agents menu after import.

- [x] Add an animation picker or preview window.
  - Show available animations for the selected agent.
  - Let the user play individual animations.
  - Keep the current agent preview table, but add drill-down details.

## Reliability

- [x] Remove runtime debug prints.
  - Remove or gate `print(name)`, `print(animation.name)`, and `print(viewController)`.
  - Use explicit debug logging only when needed.

- [x] Make agent parsing and frame rendering safer.
  - Replace risky `try!` paths with graceful failure handling.
  - Skip malformed frames where possible.
  - Show useful feedback when an imported agent cannot be loaded.
