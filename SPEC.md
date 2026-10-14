# CCM AutoStopping Menu Bar App — Spec

Menu bar (status item) app: click the icon → dropdown lists every Harness CCM
AutoStopping rule in the account, shows whether the underlying instance is
running or stopped, and gives one-click Start/Stop.

## API (verified live against account `AM8HCbDiTXGQNrTIhNl7qQ`)

Base: `https://app.harness.io/gateway/lw/api/accounts/{accountId}/autostopping`
Auth header: `x-api-key: <PAT>` (same PAT used for the regular Harness NG API).

| Action | Method | Path | Notes |
|---|---|---|---|
| List rules | GET | `/rules?accountIdentifier={accountId}` | Returns array of rule objects (`id`, `name`, `kind`, `fulfilment`, `disabled`, ...). No live power-state field. |
| Rule health/state | GET | `/rules/{id}/health?accountIdentifier={accountId}` | `{"response":{"state":"down\|active\|warmingup\|coolingdown"}}`. Works for every rule kind (instance/k8s/ecs/scale-group). This is the status source for the UI. |
| Start (warm up) | POST | `/rules/{id}/warmup?accountIdentifier={accountId}` | Body `{"forced_trigger":true}`. Drives state down→warmingup→active and (confirmed) actually starts the underlying AWS instance. |
| Stop (cool down) | POST | `/rules/{id}/cooldown?accountIdentifier={accountId}` | Body `{"force":true}`. Drives state active→coolingdown→down and actually stops the instance. |

Verified live round-trip on rule 40709 (`riley0test0`, an EC2 instance):
list → health(`down`) → POST warmup → health cycled `warmingup`→`active` while
the real EC2 instance (checked via `/rules/{id}/resources`) went
`stopped`→`pending`→`running` → POST cooldown → health cycled
`coolingdown`→`down`, instance went `stopping`→`stopped`. Left the test rule
back in its original `down`/`stopped` state.

Not used in v1 (noted for later): `/rules/{id}/resources` (exact cloud
power-state + instance id, needs `cloud_account_id`+`region`, only applies to
`kind=instance`), `toggle_state` (enables/disables the *rule*, different from
starting/stopping the instance), `/rules/savings/cumulative`.

## State → UI mapping

| `health.state` | Label | Dot |
|---|---|---|
| `active` | Running | 🟢 |
| `down` | Stopped | ⚪️ |
| `warmingup` | Starting… | 🟡 |
| `coolingdown` | Stopping… | 🟡 |
| anything else / missing | Unknown | ⚫️ |

A `disabled:true` rule shows "(disabled)" after its name; Start/Stop still
act on the underlying resource (disabling only pauses the auto-stop
scheduler, it doesn't power the resource off).

## Menu layout

```
[icon]                      <- NSStatusItem, click to open menu
──────────────────────────
riley0test0            🟢 Running     [Stop]
harness-scoe-prod1     ⚪️ Stopped     [Start]
...                                    (one row per rule, sorted by name)
──────────────────────────
Refresh Now
Last checked 12:04:03 PM
Quit
```

Each rule is a disabled "header" NSMenuItem (name + status, not clickable)
followed by an indented actionable item ("Start"/"Stop") — NSMenu items can't
mix a label and a button inline, so the action is a child item instead.
Clicking Start/Stop fires the API call, optimistically flips the row to
"Starting…"/"Stopping…", and triggers an immediate refresh.

## Config (env vars, same ones already in this shell)

- `HARNESS_PLATFORM_API_KEY` (or `HARNESS_API_KEY_<ALIAS>`) — PAT for `x-api-key`.
- `HARNESS_ACCOUNT_ID` — account identifier, also used as the URL `{accountId}`.
- `HARNESS_URL` (default `https://app.harness.io`) — base URL, for self-managed/other clusters.

No config file for v1 — single account, env-var driven, matching how this
session already authenticates. Multi-account support (switching between the
4 Harness accounts in MEMORY.md) is a listed follow-up, not v1 scope.

## Polling

Timer every 30s: re-fetch rule list + one `/health` call per rule
(concurrent, no artificial throttling — 17 rules today, fine at this scale;
add concurrency capping only if an account has hundreds of rules). Manual
"Refresh Now" item does the same on demand. After Start/Stop, refresh again
after a short delay and the next tick picks up the real end state.

## Tech choice

Plain Swift Package (`swift build`/`swift run`, no Xcode project needed),
AppKit only: `NSStatusItem` + `NSMenu` + `URLSession`. No SwiftUI
`MenuBarExtra` (needs macOS 13+ *and* a proper .app bundle to look right) and
no third-party dependencies — this is a few hundred lines, stdlib is enough.
`NSApp.setActivationPolicy(.accessory)` at launch keeps it out of the Dock
without needing an Info.plist/bundle.

## Pinning

A new view preference, independent of the Harness settings: **Show Only Pinned**
(a checkable menu item, persisted in `UserDefaults`). Pin state itself is a
set of rule IDs, also in `UserDefaults`.

- Clicking a rule's name/status row toggles its pin (left-hand icon flips
  between a hollow pin and a filled yellow pin — clicking the row is the pin
  toggle, it's not just a label anymore).
- **Show All** (default): pinned rules are sorted to the top, everything
  else follows, both groups alphabetical.
- **Show Only Pinned**: only pinned rules appear in the main list. Below
  them is an **"All Rules (N)"** item with a submenu — that submenu lists
  every unpinned rule (same name/status/pin-icon/Start/Stop as the main
  list), so you can pin more without switching back to Show All.
- Start/Stop works identically regardless of where the rule is being viewed
  from (top-level list or the All Rules submenu).

## Known gaps / out of scope for v1

- Only reads `HARNESS_PLATFORM_API_KEY`/`HARNESS_ACCOUNT_ID` — no UI for
  switching between the 4 accounts in memory. Would need a settings
  menu + Keychain storage to do properly.
- No app icon/bundle/notarization — runs via `swift run`, fine for personal
  use, not something to hand someone else as a `.app`.
- No desktop notifications on state change, no search/filter for very large
  rule counts, no per-rule savings/cost display (cumulative savings endpoint
  exists but isn't wired up).
