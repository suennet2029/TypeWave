# Option Toggle Recording Overlay Design

## Scope

Add a second trigger path on macOS without changing the existing F5-style hold-to-record flow:

- keep the current hold hotkey behavior unchanged
- add a new single-tap `Option` trigger that toggles recording on and off
- show a small floating microphone popup while recording/transcribing

## Goals

- `Option` tapped alone should start recording when idle
- `Option` tapped alone again should stop recording and begin transcription
- `Option` used with other keys must not trigger recording
- the popup must be lightweight, always-on-top, and must not steal focus

## Architecture

### Input handling

Keep the existing hold hotkey listener for the current workflow. Add a second listener dedicated to `Option` tap detection.

This listener tracks:

- whether `Option` went down
- whether any non-Option key was pressed during that key cycle
- whether the key cycle has already fired

Only a clean `Option down -> Option up` cycle with no other key presses will emit a toggle event.

### Recording control

Do not move audio capture out of Electron. The current Electron capture path is already the stable path.

The new `Option` tap emits an intent from Python service to Electron:

- idle -> request start recording
- recording -> request stop recording

If the app is currently transcribing, ignore the toggle request and keep the state unchanged.

### Floating overlay

Electron main process creates a dedicated frameless overlay window:

- transparent background
- always on top
- not focusable
- hidden from Dock and task switchers
- fixed size, centered near the bottom of the active screen

Renderer view for the overlay is minimal and only displays recording state:

- `recording`: blue circular badge with white microphone
- `transcribing`: same shell with lightweight processing feedback
- `done` or `error`: short-lived terminal state, then auto-hide

## Data Flow

1. User taps `Option` alone.
2. Python listener emits a service event such as `toggle_recording_shortcut`.
3. Electron main receives the event and forwards a UI event to the hidden renderer controller.
4. Renderer starts or stops capture using the existing working path.
5. Electron main updates the overlay window state based on service/log events.
6. Overlay auto-hides after completion or failure.

## Error Handling

- If `Option` is combined with another key, discard that cycle.
- If microphone permission is missing, do not enter recording; show the error state briefly and keep existing error messaging.
- If transcription is already in progress, ignore further toggle requests until it settles.
- If overlay creation fails, keep recording functionality working and fall back to logs/notifications only.

## Testing

- verify the existing hold hotkey still works unchanged
- verify `Option` single tap toggles start and stop
- verify `Option` plus any other key does not trigger recording
- verify no repeated toggles on long press or keyboard repeat
- verify overlay appears on start, updates during transcription, and hides after completion
- verify failure states do not leave the overlay stuck on screen
