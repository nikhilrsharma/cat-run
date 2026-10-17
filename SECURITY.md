# Security and release verification

## Permissions and data

The packaged app requests only `com.apple.security.app-sandbox`. Its signed entitlement file contains no network client/server, user-selected file, home-folder, device, Apple Events, or temporary-exception entitlements. The build enables hardened runtime and does not enable JIT, unsigned executable memory, debugging, or disabled library validation.

The app reads system power information and holds time-limited power assertions through macOS APIs. It does not need Accessibility, Input Monitoring, Screen Recording, Full Disk Access, administrator rights, or notification permission for its intended features. No password or signing credential is stored in the source.

Preferences and recently used durations are stored locally through macOS preferences. Version 0.2.0 also keeps one local session record: a random identifier, start time, state, stop reason, and known end time. It contains no battery trace, activity log, account, or contact details. It is used for honest interruption recovery, never to resume a timer. App Sandbox allows access to the app's own container; that access is needed to save this state. macOS frameworks may access their own permitted system resources. A sandbox is a security boundary, not a claim that the app has no filesystem access at all.

The session record is atomically replaced, limited to 16 KiB, and validated before use. New record directories use owner-only access and the record uses owner read/write permissions. A malformed regular record may be preserved with a unique `corrupt-` suffix; unexpected filesystem objects are rejected. Records are written only at session boundaries, not on a heartbeat. Storage failure prevents a new activation when its marker cannot be written. An interrupted process cannot supply an exact stop time; recovery explicitly marks that time unknown.

Start at login uses the macOS login-item service and is opt-in. Enabling it is a persistent system action and can require user approval in System Settings. The app does not install a privileged helper or modify shell startup files.

There is no updater, remote code, network service, analytics, or telemetry. The app's operation is local. Code signing and sandboxing do not guarantee the absence of bugs; inspect the exact release artifact and test it on supported hardware.

## Safety behavior to verify

- A valid 90% reading with no runtime estimate after wake or unplugging must allow a 15-minute timer without a forecast warning. Unknown runtime is not a low-battery prediction. Verify 30-second forecast settling, AC/wake invalidation, long observation gaps, and invalid runtime sentinels.
- Below 15% battery: refuse activation and stop an active timer, both on battery and while connected to power. Confirm the boundary at 15% and 14%.
- Missing battery readings on a battery-equipped Mac: do not silently assume a safe level. A desktop without an internal battery must be distinguished from an unreadable laptop battery.
- Confirm that the app releases both system and display assertions on stop, expiry, low battery, and quit. Confirm that terminating the process leaves no assertion owned by that process.
- Confirm independent 10-second active-only charge checks, a 30-second UI heartbeat threshold, and OS assertion leases of at most 45 seconds or the remaining duration. Simulate delayed battery reads, a stalled main thread, and a stalled guard; expired protection must not be silently reacquired. These are scheduling and lease limits, not a guarantee that physical charge cannot fall below 15% between reports.
- Verify sleep cancellation through the ordinary notification, wake fallback, and continuous-versus-awake clock comparison. Locking the screen and display-only sleep should not be mistaken for whole-system sleep. Check external-monitor closed-lid behavior separately.
- Verify the deadline ordering: a low reading detected before expiry stops for battery; a reading first obtained after an awake deadline does not rewrite completion. Sleep evidence takes priority over claiming successful completion.
- Confirm that the display-awake choice and start-at-login setting cannot be changed during an active timer.
- Confirm startup restores preferences and the latest recorded outcome while leaving the timer inactive. Verify that failed starts do not add recent durations, crashes recover an interruption with unknown end time, and old callbacks cannot overwrite a newer session.
- Verify user switching and logout/shutdown stop the timer. Once stopped, cancelling shutdown or switching back must not restart it. Real notification ordering requires a hardware session check.
- Unplug during a running timer: it should continue when charge remains valid and at least 15%. A later usable low projection belongs in the window notice, without a modal interruption; a missing forecast should remain quiet.
- Check malformed, oversized, unsupported-version, and symbolic-link journal inputs. A corrupt record must not be presented as a completed timer; a failed record write must not start unrecorded protection.
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
