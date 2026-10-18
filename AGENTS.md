# Mac Coffee development

- Build and test on the Mac mini. Do not create MacBook development copies or build artifacts.
- Keep this a native macOS menu bar app with `LSUIElement`; normal launch and diagnostics must start with no awake session.
- Use the app-owned `/usr/bin/caffeinate` Process for awake assertions. The explicit `Keep awake, screen off now` action may invoke fixed `/usr/bin/pmset displaysleepnow` to sleep only the display; never invoke system `sleepnow` from the app. Keep fixed argument arrays and terminate only the Process instance Mac Coffee launched.
- Keep a finite session deadline absolute across display preference changes. Caffeinate's `-t`, the app countdown, and the helper timer must use that same deadline.
- Preserve the lid-awake helper's code identity checks, session ownership, journal recovery, heartbeat, battery and thermal safeguards, policy verification, and closed-lid expiry behavior.
- Keep Mac Coffee's application, helper, launch daemon, mach service, and preferences identities unique to this app.
- Maintenance options must remain read-only unless an explicit register or repair option was supplied. Never start an awake session from diagnostics, previews, registration, or repair.
- Do not add telemetry or network access.
- Run `swift test` and `Scripts/build-app.sh` after changes that affect the app or helper.
