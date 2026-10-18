# Mac Coffee

Mac Coffee is a native macOS menu bar app that keeps your Mac awake for a chosen time.

## Features

- Keep the Mac awake with an owned `caffeinate` process.
- Optionally keep the display awake while the session is active.
- Choose 1, 15, 30, 60, or 120 minutes, a custom whole-minute timer from 1 to 1,440 minutes, or keep the session running until stopped. The default is 60 minutes.
- Optional settings include opening at login (with the awake session still off), Command-Option-C, stopping on battery, and a timer-end notification.
- Advanced settings can keep disks awake, prevent system sleep while on AC power, briefly wake the display on explicit start, or start a finite timer when the lid first closes.
- On Macs that report clamshell state, use the separately registered helper to preserve the lid-closed safety behavior. The helper restores normal sleep at the deadline and requests sleep when the lid is closed.
- Each app launch starts with the awake session off. The display and timer choices are saved. Timer presets remain quick choices, and Custom accepts any whole number from 1 to 1,440 minutes.
- No telemetry and no network access.

The helper uses its own Mac Coffee launch daemon identity. macOS may require approval in System Settings > General > Login Items before lid-closed support is ready. Macs that do not report clamshell state use ordinary `caffeinate` and do not register the helper.

## Build

Requires macOS 14 or later and Swift 5.9 or later.

```sh
swift test
Scripts/build-app.sh
open dist/MacCoffee.app
```

The build script creates and ad-hoc signs `dist/MacCoffee.app`. It is not notarized.

## Use

Click the coffee cup in the menu bar. Choose a stop time, then turn on **Keep awake**. **Keep screen on** is a saved preference and only adds the display assertion while the awake session is on. Changing that preference during a session restarts only the owned `caffeinate` process with the same absolute deadline. Additional assertions are opt-in: keep disks awake, prevent system sleep while connected to AC, or send a five-second user-activity pulse when explicitly starting. The pulse runs only when the lid is known open on a laptop.

On a clamshell-capable Mac, register the helper from the menu, then approve it in System Settings when prompted. With Start timer when lid closes enabled and a finite timer selected, Mac Coffee starts the awake session immediately, waits for the first lid closure to begin the countdown, and never resets the deadline on reopen. The helper restores normal sleep behavior and requests sleep when that deadline expires with the lid closed. Stop on battery ends a session when the power source is confirmed to be battery. The lid helper restores normal sleep conservatively if power state becomes unknown. Timer notifications are requested only when you enable that option and are sent only after a normal timer expiry. The app will not start a partial awake session if helper setup or helper activation fails. The helper protects low battery, critical thermal state, lost heartbeats, interrupted app connections, and recovery after a helper restart. When a timed session expires with the lid closed, it restores the normal sleep policy and then requests sleep.

The helper can also be inspected or maintained from Terminal using the executable inside the built app:

```sh
dist/MacCoffee.app/Contents/MacOS/MacCoffee --diagnostic
dist/MacCoffee.app/Contents/MacOS/MacCoffee --register-lid-helper
dist/MacCoffee.app/Contents/MacOS/MacCoffee --repair-lid-helper
dist/MacCoffee.app/Contents/MacOS/MacCoffee --show
```

Diagnostics only read state. Registration and repair do not start an awake session. `--show` opens the menu bar popover for review.
