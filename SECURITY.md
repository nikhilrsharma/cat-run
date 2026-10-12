# Security and release verification

## Permissions and data

The packaged app requests only `com.apple.security.app-sandbox`. Its signed entitlement file contains no network client/server, user-selected file, home-folder, device, Apple Events, or temporary-exception entitlements. The build enables hardened runtime and does not enable JIT, unsigned executable memory, debugging, or disabled library validation.

The app reads system power information and holds time-limited power assertions through macOS APIs. It does not need Accessibility, Input Monitoring, Screen Recording, Full Disk Access, administrator rights, or notification permission for its intended features. No password or signing credential is stored in the source.

Preferences and recently used durations are stored locally through macOS preferences. App Sandbox allows access to the app's own container; that access is needed to save settings. macOS frameworks may access their own permitted system resources. A sandbox is a security boundary, not a claim that the app has no filesystem access at all.

Start at login uses the macOS login-item service and is opt-in. Enabling it is a persistent system action and can require user approval in System Settings. The app does not install a privileged helper or modify shell startup files.

There is no updater, remote code, network service, analytics, or telemetry. The app's operation is local. Code signing and sandboxing do not guarantee the absence of bugs; inspect the exact release artifact and test it on supported hardware.

## Safety behavior to verify

- Below 15% battery: refuse activation and stop an active timer, both on battery and while connected to power. Confirm the boundary at 15% and 14%.
- Missing battery readings on a battery-equipped Mac: do not silently assume a safe level. A desktop without an internal battery must be distinguished from an unreadable laptop battery.
- Confirm that the app releases both system and display assertions on stop, expiry, low battery, and quit. Confirm that terminating the process leaves no assertion owned by that process.
- Confirm that the display-awake choice and start-at-login setting cannot be changed during an active timer.
- Confirm startup restores preferences while leaving the timer inactive. Verify that failed starts do not add recent durations.
- Verify sleep, wake, AC changes, screen locking, display changes, and window resizing on a real Mac. Power assertions cannot override all macOS sleep causes.
- Test login registration, the approval-required state, disabling it, and an actual logout/login using the installed bundle. Do not enable login during an automated test.
- Inspect idle CPU use and active animation behavior. Recheck with Reduce Motion enabled and with the screen asleep.
- Verify the bundle's exact signature and entitlements after any packaging change:

```sh
codesign --verify --deep --strict 'build/Cat Run.app'
codesign --display --entitlements :- 'build/Cat Run.app'
codesign --display --verbose=4 'build/Cat Run.app'
```

Release archives should contain the app or source as appropriate, not build caches, local test logs, signing materials, personal paths, or user preferences. Strip those artifacts from source releases. When reporting an issue, omit personal system data and redact any identifying path in a log.
