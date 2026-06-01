# Tracking Logic Refactor — Plan

Status: proposal for review. Nothing here is implemented yet.

This document describes a refactor of the time‑tracking logic in
`TrackingManager` (plus supporting types) so that the app behaves sensibly
when the machine sleeps/locks, when the network/VPN is intermittent, and when
the user does not react to a checkpoint immediately.

---

## 1. How tracking works today (as‑is)

`TrackingManager.Session` holds:

```
issue, startedAt, lastCheckpointAt, awaitingContinuation, accumulatedMinutes
```

Flow:

1. **Start** → schedule a `Task.sleep(checkpointMinutes)` checkpoint.
2. **Checkpoint fires** (`handleCheckpoint`) → add `checkpointMinutes` to
   `accumulatedMinutes`, set `lastCheckpointAt = now`, set
   `awaitingContinuation = true`, send a notification + a reminder loop every
   180 s. **Accumulation stops here** until the user acts.
3. User chooses:
   - **Continue** (`continueAfterCheckpoint`) → `awaitingContinuation = false`,
     `lastCheckpointAt = now`, reschedule. The time between the checkpoint
     firing and clicking Continue is **discarded**.
   - **Stop & Book accumulated** (`finishAwaitingSession`) → book
     `accumulatedMinutes`.
   - **Stop & Book All** (`finishAwaitingSessionIncludingElapsed`) → book
     `accumulatedMinutes + minutesSinceLastCheckpoint`.
4. **Stop while running** (`stopTracking`) → book `accumulatedMinutes +
   partial`.
5. **Restart** (`restorePersistedSessionIfNeeded`) → if awaiting, re‑notify;
   else if a full interval elapsed, apply exactly **one** checkpoint at the
   theoretical fire time and go to awaiting; else reschedule the remainder.

Booking uploads via `GitLabAPI.addSpentTime`; failures land in
`BookingHistoryStore` as `pending` and must be retried **manually**.

---

## 2. Why it doesn't make sense in use

1. **Missing a checkpoint loses real work time.** Accumulation pauses at the
   checkpoint. If you keep working but don't click *Continue* for 10 minutes,
   those 10 minutes vanish when you finally click it. The UI even labels the
   gap as "Paused", which is wrong if you were actually working. This directly
   contradicts the requested behavior: *resume tracking and check with the user
   when he notices; keep all results open at all times.*

2. **No concept of "away".** There is **zero** sleep/lock/idle detection. A
   `Task.sleep` checkpoint drifts arbitrarily across a system sleep, and
   wall‑clock based "book all" silently counts hours of sleep as work. The app
   cannot tell the difference between *stepped away for a break* (should not
   count) and *rolled the laptop to a colleague's desk and kept working*
   (should count) — and it never asks.

3. **Intermittent VPN/network is only half‑handled.** Booking failures are
   queued as `pending`, which is good, but there is **no automatic retry** when
   connectivity returns; the user must open Booking History and retry by hand.
   Token refresh (`currentAuthorization`) can also fail transiently off‑VPN.

4. **Three overlapping stop/book code paths** (`stopTracking`,
   `finishAwaitingSession`, `finishAwaitingSessionIncludingElapsed`) encode the
   same arithmetic in slightly different ways — easy to drift, hard to reason
   about.

5. **Docs and code disagree.** `AGENTS.md` claims the app "books 20 minutes
   every 20 minutes"; the code only accumulates locally and books on stop.

---

## 3. New mental model

Replace the single `accumulatedMinutes + lastCheckpointAt` counter with an
**interval (segment) log** per session. A session is a list of time intervals,
each tagged with a state:

- `confirmed` — counted as work.
- `uncertain` — an "away" gap (sleep / lock / idle) that the user has not yet
  classified. Held open until the user decides; **never auto‑discarded,
  never auto‑counted.**

```
Session
  issue
  startedAt
  segments: [Segment]          // closed intervals
  openSegmentStart: Date?      // the currently running confirmed interval
  state: .running | .away      // away = machine is asleep/locked/idle now

Segment
  start: Date
  end: Date
  kind: .confirmed | .uncertain
  // for .uncertain: resolution: .undecided | .counted | .discarded
```

Booked minutes = sum of `confirmed` intervals + `uncertain` intervals the user
marked `counted` + the still‑open running interval. This model makes the three
problem areas fall out naturally:

- **Checkpoint** becomes a non‑blocking *check‑in*: it never closes the open
  segment, so missing it costs nothing.
- **Away** periods become `uncertain` segments the user reconciles on return.
- **Network** is fully orthogonal to the timing model.

Backwards compatibility: the existing pure functions (`minutesBetween`,
`applyCheckpoint`) and their tests are kept or re‑expressed; persistence
migrates the old `PersistedSession` into a single open/closed segment.

---

## 4. Detailed design

### 4.1 Checkpoint = non‑blocking check‑in (keep tracking, reconcile later)

- Remove the `awaitingContinuation` *pause*. Tracking keeps running through and
  past every checkpoint; the open confirmed segment is never closed by a
  checkpoint.
- At each `checkpointMinutes` boundary, fire a check‑in notification ("Still on
  #42? N min tracked.") and keep the existing reminder loop nudging until
  acknowledged — but **purely informational**. Actions on the notification:
  - **Keep going** → just dismiss; tracking already continued.
  - **Stop & book** → close the open segment and book the total.
  - (optional) **Switch issue** → stop+book current, start the chosen one.
- The menu‑bar UI shows a live "Currently tracking · N min (last check‑in
  Xm ago)" instead of an "Awaiting Confirmation / Paused" state.
- Net effect: if the user doesn't react, no time is lost; when they notice,
  they reconcile. "Keep all results open at all times" is satisfied because the
  running total and any uncertain gaps remain visible and editable.

### 4.2 Away detection (sleep / lock / idle / fast user switching)

Add an `ActivityMonitor` (`@MainActor`) that publishes away/return events from:

| Source | API |
|--------|-----|
| System sleep/wake | `NSWorkspace.willSleepNotification` / `didWakeNotification` |
| Display sleep | `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` |
| Screen lock/unlock | `DistributedNotificationCenter` `com.apple.screenIsLocked` / `…Unlocked` |
| Fast user switch | `NSWorkspace.sessionDidResignActiveNotification` / `…BecomeActiveNotification` |
| Input idle (no lock) | poll `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .anyInputEventType)` against an idle threshold |

Behavior when an **away** event arrives while a session is running:
1. Close the open confirmed segment at the away timestamp (`awayStart`).
2. Enter `.away`; record `awayStart`.

When a **return** event arrives:
1. Open an `uncertain` segment `[awayStart, returnTime]` with
   `resolution = .undecided`.
2. **Resume tracking automatically** — open a new confirmed segment at
   `returnTime`. (Requirement: "resume tracking … as we do now.")
3. If `awayDuration < ignoreThreshold` (e.g. 90 s — quick lock, screen
   blanking), auto‑resolve the gap as `counted` and don't prompt. Otherwise
   leave it `undecided` and surface a reconciliation prompt (4.3).

Notes / decisions:
- Use the **wall clock** for segment boundaries (`Date`), not a monotonic
  timer, so sleeping the machine for 2 h produces a correct 2 h `uncertain`
  gap rather than drift.
- "Rolling to a colleague's desk" is exactly why away is *uncertain*, not
  auto‑discarded: the user may have kept working. They decide on return.
- Idle polling cadence ~30–60 s; only active while a session is running.

### 4.3 Reconciliation (keep all results open)

On return from a long away period, do **not** block with a modal. Instead:
- Post a notification: *"You were away 47 min while tracking #42 — count it as
  work?"* with actions **Count it** / **Discard** / **Decide later**.
- Show the unresolved gap inline in the menu‑bar window (a small banner on the
  active session card) with the same three actions, persisting until resolved.
- Multiple unresolved gaps can stack; each is independently resolvable.
- `counted` adds the gap to the booked total; `discarded` excludes it; nothing
  is finalized/uploaded until the user stops the session (or per‑checkpoint
  booking is enabled — see 4.5). Unresolved gaps default to **excluded** from
  any interim display total but remain visible and changeable.

### 4.4 Network / VPN resilience

- Add a lightweight reachability/auto‑retry layer:
  - On booking failure classified as transient (offline, timeout, DNS, TLS,
    401→refresh‑then‑retry), keep the entry `pending` (as today) **and**
    schedule automatic retry with capped exponential backoff.
  - Trigger an immediate retry sweep of `pending` bookings when the network
    path becomes satisfied (`NWPathMonitor`) or on app foreground/wake.
  - Distinguish transient vs permanent (404 issue gone, 403) so permanent
    failures stop retrying and surface clearly.
- Keep the manual *Retry* / *Retry all* buttons as a fallback.
- Session persistence already survives restarts; ensure the active session and
  its segment log are persisted on every mutation so an off‑VPN crash never
  loses tracked time.

### 4.5 Booking cadence (resolve the docs/code mismatch)

Pick one and make docs match:
- **Recommended:** keep *book‑on‑stop* (current real behavior) — simplest,
  fewest GitLab notes, and the pending queue covers failures. Update
  `AGENTS.md` to stop claiming per‑checkpoint booking.
- **Alternative:** book each confirmed checkpoint incrementally (less data loss
  if the app dies), at the cost of more `/spend` notes and more network calls
  while off‑VPN. Only worth it if interim durability matters more than tidy
  history.

---

## 5. Component‑by‑component changes

- **`TrackingManager.swift`**
  - Replace `Session` fields with the segment‑log model (§3).
  - Delete `awaitingContinuation` pause semantics; collapse `stopTracking`,
    `finishAwaitingSession`, `finishAwaitingSessionIncludingElapsed` into a
    single `stopAndBook(includeUncertain:)` built on a pure
    `bookedMinutes(for:asOf:)` helper.
  - Make checkpoint non‑blocking; keep `checkpointTask` only for the reminder
    cadence.
  - Wire `ActivityMonitor` events → `beginAway(at:)` / `endAway(at:)`.
  - Auto‑retry pending bookings on reconnect/wake.
- **New `ActivityMonitor.swift`** — sleep/lock/idle/user‑switch → away/return
  events (§4.2). Pure, injectable, unit‑testable boundary times.
- **`SessionStore.swift` / `PersistedSession`** — persist the segment log;
  add a migration from the old flat fields → one closed/open segment.
- **`NotificationCoordinator.swift`** — reframe checkpoint copy as a non‑
  blocking check‑in; add a reconciliation notification category (Count it /
  Discard / Decide later); keep the reminder loop but never imply a pause.
- **`MenuBarViews.swift`** — replace "Awaiting Confirmation / Paused" UI with a
  live running total + last‑check‑in time; add the unresolved‑gap banner with
  Count/Discard/Decide‑later; simplify the stop buttons to one primary action.
- **New `Reachability`/retry helper** (or fold into `GitLabAPI`/`TrackingManager`)
  using `NWPathMonitor` (§4.4).
- **`AGENTS.md`** — correct the booking‑cadence description and document the new
  away/reconciliation model.

---

## 6. Edge cases & tests

Extend `TrackingCalculationTests` (logic stays pure/testable):
- Sleep before first checkpoint; wake after several intervals → correct
  confirmed vs uncertain split.
- Lock for 30 s (< ignore threshold) → auto‑counted, no prompt.
- Lock for 45 min → one `undecided` gap; `counted` vs `discarded` totals.
- Missing the checkpoint for 10 min while working → those 10 min **kept** (the
  current regression where they're lost is fixed).
- Multiple stacked unresolved gaps resolved independently.
- Clock moved backwards during a gap → clamp to 0/`minutesBetween` min‑1 rules.
- Restart mid‑away and mid‑undecided‑gap → state restored, prompt re‑shown.
- Booking fails offline then auto‑retries successfully on reconnect.
- Migration: old `PersistedSession` decodes into the new model and books the
  same minutes it would have before.

---

## 7. Rollout phases

1. **Refactor to the segment model** behind the existing behavior (no UX change
   yet): new `Session`, pure helpers, persistence + migration, tests green.
2. **Non‑blocking checkpoint** (§4.1): drop the pause, update UI + notification
   copy.
3. **Away detection + reconciliation** (§4.2–4.3): `ActivityMonitor`, gap
   banners, notifications.
4. **Network auto‑retry** (§4.4): reachability sweep + backoff.
5. **Docs**: fix `AGENTS.md`, finalize booking cadence (§4.5).

Each phase is independently shippable and testable.

---

## 8. Open questions for the maintainer

1. **Booking cadence** — keep book‑on‑stop (recommended) or move to per‑
   checkpoint incremental booking?
2. **Idle threshold** — what counts as "away" without a lock (e.g. 5 min of no
   input)? And the short‑lock ignore threshold (proposed 90 s)?
3. **Default for unresolved gaps** at stop time — exclude (recommended,
   conservative) or prompt one last time before booking?
4. **Idle without lock** — should pure input‑inactivity create uncertain gaps,
   or only real sleep/lock/user‑switch events?
