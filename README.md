# CCM AutoStopping Menu Bar

Mac menu bar app: lists all Harness CCM AutoStopping rules, shows running/stopped
status, and gives one-click Start/Stop. See `SPEC.md` for the design and the API
calls it's built on (verified live against a real account/instance).

## For end users (no terminal, no Xcode)

1. Get `CCMAutoStoppingBar-<version>-macos-arm64.zip` from whoever built it (see
   "Building the distributable" below) and unzip it — you'll get
   `CCMAutoStoppingBar.app`.
2. Drag it into `/Applications` (or just double-click it where it is).
3. **First launch only**: double-clicking will be blocked by Gatekeeper
   ("CCMAutoStoppingBar can't be opened because it is from an unidentified
   developer") because this isn't signed with a paid Apple Developer ID.
   Instead: **right-click the app → Open → Open** (or System Settings →
   Privacy & Security → scroll down → "Open Anyway" after the first blocked
   attempt). You only need to do this once.
4. A ☁️-ish plug icon appears in the menu bar. Click it — if nothing is
   configured yet, a Settings window pops up automatically. Paste in your
   Harness URL (defaults to `https://app.harness.io`) and your Harness API
   key (`pat.xxxxx...`) and hit Save. The account ID is read out of the key
   automatically.
5. Quit from the dropdown's "Quit" item (it has no Dock icon/window to close).

Only works on Apple Silicon Macs today (arm64 build only — see "Known gaps").

## Building the distributable (for whoever is packaging a release)

```sh
./Scripts/make-app.sh [version]   # version defaults to 0.0.1
```

This builds a release binary, wraps it into `dist/CCMAutoStoppingBar.app`
(with a proper `Info.plist`, `LSUIElement` so it never shows in the Dock),
ad-hoc signs it so it'll run at all, and zips it to
`dist/CCMAutoStoppingBar-<version>-macos-arm64.zip`. Share that zip (Slack,
shared drive, internal wiki — wherever). Re-run the script any time you want
to cut a new build after code changes.

## Developing / running from source

```sh
swift run
```

Needs these env vars set, *or* just use the in-app Settings window once it's
running (Settings takes priority over env vars either way):

- `HARNESS_ACCOUNT_ID` (optional — derived from the API key if omitted)
- `HARNESS_PLATFORM_API_KEY` (or `HARNESS_API_KEY`)
- `HARNESS_URL` (optional, defaults to `https://app.harness.io`)

## Layout

- `Package.swift` — plain SPM executable, no dependencies.
- `Sources/CCMAutoStoppingBar/main.swift` — the whole app (AppKit status item,
  Settings window, Keychain storage, Harness API client).
- `Scripts/make-app.sh` — builds and packages the `.app` + zip for distribution.
- `dist/` — build output (gitignored; regenerate with `make-app.sh`).

## Known gaps

- **Unsigned**: no Apple Developer ID certificate, so no notarization — every
  new machine needs the right-click-Open dance once. A real Developer ID
  ($99/yr Apple Developer Program) + `codesign`/`notarytool` would remove
  this entirely; out of scope until someone wants to pay for that.
- **Apple Silicon only**: `make-app.sh` builds a single-arch arm64 binary.
  Intel Mac support would need a universal (arm64 + x86_64) build via
  `swift build --triple x86_64-apple-macosx12.0` + `lipo`, not set up yet.
- **No auto-update**: a new release means re-downloading and re-replacing the
  `.app` by hand.
