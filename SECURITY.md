# Security and release verification

Version 0.3.3 · Updated October 24, 2026

## Permissions and data

The packaged app requests only `com.apple.security.app-sandbox`. Its signed entitlement file contains no network client/server, user-selected file, home-folder, device, Apple Events, or temporary-exception entitlements. The build enables hardened runtime and does not enable JIT, unsigned executable memory, debugging, or disabled library validation.

The app reads system power information and holds time-limited power assertions through macOS APIs. It does not need Accessibility, Input Monitoring, Screen Recording, Full Disk Access, administrator rights, or notification permission for its intended features. No password or signing credential is stored in the source.

Preferences and the three recently used durations are stored locally through macOS preferences. They are not an activity history and are not encrypted by Cat Run. Version 0.3.0 adds a local activity log and encrypts both that log and the separate latest-session recovery record. Neither contains account, contact, file-path, device-identifier, or browsing data. App Sandbox permits access to the app's own container; that access is needed to save this state. macOS frameworks may access their own permitted system resources. A sandbox is a security boundary, not a claim that the app has no filesystem access at all.

## Encrypted local history

Activity logs and the latest-session record use CryptoKit AES-GCM with a 256-bit key, a fresh nonce for each write, and distinct authenticated contexts for the two formats. The key is stored in Cat Run's own login-Keychain item; it is never embedded in source, placed beside the data, or included in release archives. The Keychain item's default trusted-application access is restricted to the app creating it. Cat Run does not broaden that access list. A signing change or Keychain state can require macOS approval before a later build can read the key.

Missing, inaccessible, or invalid keys do not trigger a plaintext fallback. When existing encrypted data is present or its location cannot be inspected safely, Cat Run refuses to generate a replacement key. Unreadable or unauthenticated history is reported as unavailable and is not silently replaced. Key access is cached in memory after success. A temporary failure may recover when Keychain access becomes available; a lost key cannot be reconstructed from the encrypted files. The latest-session record must be saved before a timer starts, so failure to save that safety marker prevents activation.

The activity store keeps a rolling seven days of entries, newest recorded first, with an additional limit of 4,000 events and a 2 MiB encrypted file. Event descriptions are bounded, single-line, app-owned text. Routine countdown ticks, animation frames, and battery polling are not logged. Recording order remains stable across wall-clock changes, and an authenticated retention reference prevents a backward clock correction from restoring already expired entries. Entries may be removed earlier if the count limit is reached.

**Copy logs** writes the available retained verified activity to the clipboard only after an explicit click. It includes offscreen entries in recording order with date groups and local timestamps. This user-requested copy is plaintext for pasting into another application; the on-disk history and key remain encrypted and are not exported. Empty or unavailable history cannot be copied. No automatic copying, plaintext export file, new entitlement, or network access is added.

Retention is checked on startup, log access, and writes, and approximately hourly while the app is running. Expired data is removed at the next such check; Cat Run cannot perform cleanup while it is closed. Unreadable ciphertext is retained for possible key recovery until its file age reaches seven days, then removed with an explicit unavailable-history message. A run marker is renewed if retention removes it while the app remains open, so long-running sessions can still report an unrecorded exit without claiming a new launch.

The audit directory uses owner-only access (`0700`), and its files use owner read/write permissions (`0600`). The store bounds reads, rejects symbolic links, hard links, and unexpected file types, and atomically replaces authenticated ciphertext. Interrupted temporary writes contain ciphertext only and are removed on the next store access. Encryption authenticates the stored content; this is a diagnostic history, not a tamper-proof forensic record or a defense against deletion by someone who already controls the user's account.

The separate latest-session record is limited to 16 KiB and contains a random session identifier, start time, state, stop reason, and a known stop or detection time. It is retained as the current outcome, independently of the seven-day activity history, and never resumes a timer. Existing valid legacy records are encrypted in place without a plaintext backup. Quarantine maintenance keeps at most three recognized regular copies for seven days; bounded legacy copies are encrypted when key access is available, without resetting their age. Expired regular copies are removed before key access. Oversized recent copies are rejected until they expire. Unexpected filesystem objects are left untouched, and no quarantine is used to restore a session.

Audit encryption and disk writes run on a separate queue. Power assertions are released before terminal journal or audit persistence, and audit shutdown flushing has a bounded wait. A logging failure must not keep the Mac awake or suppress a known stop reason. Recovered logging includes a concise warning that some events may be missing.

A crash, force quit, or sudden power loss may prevent the final event from being written. Recovery reports an unrecorded exit or interrupted timer with an unknown cause and stop time; the detection time is identified separately. Missed sleep notifications similarly use detection wording instead of inventing a sleep instant. Logout, restart, and shutdown share a combined description where macOS does not identify which event occurred.

Start at login uses the macOS login-item service and is opt-in. Enabling it is a persistent system action and can require user approval in System Settings. The app does not install a privileged helper or modify shell startup files.

There is no updater, remote code, network service, analytics, or telemetry. The app's operation is local. Code signing and sandboxing do not guarantee the absence of bugs; inspect the exact release artifact and test it on supported hardware.

## Safety behavior to verify

- A valid 90% reading with no runtime estimate after wake or unplugging must allow a 15-minute timer without a forecast warning. Unknown runtime is not a low-battery prediction. Verify 30-second forecast settling, AC/wake invalidation, long observation gaps, and invalid runtime sentinels.
- Below 15% battery: refuse activation and stop an active timer, both on battery and while connected to power. Confirm the boundary at 15% and 14%.
- Exercise disagreeing fresh readers: a safe guard sample followed by a below-15% or unavailable interface sample must stop the active session, without waiting for another periodic read. A newer safe snapshot must not erase the unsafe observation. Preserve existing expiry/sleep priority and session-token checks.
- Verify extension risk uses all remaining time plus 15 minutes, rapid requests add exactly one increment each, elapsed time does not replenish the six-hour total allowance, and the capped button clearly shows 06h limit. Keep the active slider aligned with remaining time through the final minutes.
- Test open warning updates after forecast, charge, remaining-time, and AC changes. Continue must recheck safety and the current session; Cancel or stale confirmation adds no time. A risk disappearing while the sheet is open must not automatically extend the timer.
- Missing battery readings on a battery-equipped Mac: do not silently assume a safe level. A desktop without an internal battery must be distinguished from an unreadable laptop battery.
- Confirm that the app releases both system and display assertions on stop, expiry, low battery, and quit. Confirm that terminating the process leaves no assertion owned by that process.
- Confirm the 30-second fallback interval for active-only periodic battery reads and immediate fresh reads before start/extension, on launch/activation/wake, and on macOS power-source notifications. Event-driven checks must not wait for the fallback. Confirm that idle periods perform no periodic battery polling.
- Confirm that the independent guard still runs every 10 seconds, with up to one second of scheduling tolerance, to check responsiveness, sleep, deadlines, and assertion leases. Retain the 30-second UI heartbeat threshold and OS assertion leases of at most 45 seconds or the remaining duration. Simulate delayed battery reads, a stalled main thread, and a stalled guard; expired protection must not be silently reacquired. The 30-second battery fallback is a target interval, not a maximum detection-delay guarantee: macOS reporting or scheduling can delay a reading, and physical charge can fall below 15% between reports. Reduced query work may produce modest savings, but no battery-life gain has been measured.
- Verify sleep cancellation through the ordinary notification, wake fallback, and continuous-versus-awake clock comparison. Locking the screen and display-only sleep should not be mistaken for whole-system sleep. Check external-monitor closed-lid behavior separately.
- Verify the deadline ordering: a low reading detected before expiry stops for battery; a reading first obtained after an awake deadline does not rewrite completion. Sleep evidence takes priority over claiming successful completion.
- Confirm that the display-awake choice and start-at-login setting cannot be changed during an active timer.
- Confirm startup restores preferences and the latest recorded outcome while leaving the timer inactive. Verify that failed starts do not add recent durations, crashes recover an interruption with unknown end time, and old callbacks cannot overwrite a newer session.
- Verify user switching and logout/shutdown stop the timer. Once stopped, cancelling shutdown or switching back must not restart it. Real notification ordering requires a hardware session check.
- Unplug during a running timer: it should continue when charge remains valid and at least 15%. A later usable low projection belongs in the window notice, without a modal interruption; a missing forecast should remain quiet.
- Check malformed, oversized, unsupported-version, and symbolic-link journal inputs. A corrupt record must not be presented as a completed timer; a failed record write must not start unrecorded protection.
- Check authenticated round trips, tampered ciphertext, wrong or missing keys, temporary Keychain denial, unavailable storage, and recovery without plaintext fallback. Verify that existing encrypted data in either the journal or logs prevents replacement-key creation.
- Verify local log timestamps and timezone labels remain correct without the removed “Local time” heading. Verify log order after equal timestamps and wall-clock rollback; rolling seven-day expiry; the 4,000-entry and 2 MiB bounds; owner-only permissions; and cleanup after an interrupted atomic write. Test legacy journal/quarantine encryption, expiration, count limits, and unsafe-file rejection.
- Verify compact Activity rows and Copy logs at both window limits. Copy all retained verified entries, not only visible rows; retain recording order, repeated day groups, timezone offsets, and long messages. Test empty/unavailable history and clipboard-write failures using an isolated pasteboard. Opening logs must not change the clipboard; no copy failure should be reported as success.
- Verify app-run marker renewal after retention, unknown-cause recovery after force quit, and clean-quit deduplication. A delayed or failed log write must not delay release of power assertions. Exercise actual Keychain approval and signing changes on an installed bundle; injected-key tests do not prove those macOS interactions.
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
