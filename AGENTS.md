# AI Agent Handoff

This repository contains a macOS menu bar app for lightweight GitLab issue tracking and issue creation.

## Product Summary

- The app runs as a menu bar-only app.
- It shows currently assigned open GitLab issues for the authenticated user.
- Clicking an issue starts local time tracking.
- Tracking runs continuously; every 20 minutes (configurable) it posts a non-blocking check-in notification but keeps counting time.
- Tracked time is booked to the GitLab issue when the user stops — not at every checkpoint.
- The app can create a new issue in a selected GitLab project.
- After creating an issue, the create section collapses and the assigned issue list refreshes.

## Important Current Decisions

- Issue status handling was intentionally removed.
- There is no status dropdown in the UI.
- The app does not post GitLab `/status` quick actions.
- A GitLab group setting still exists and is used to scope the create-issue project picker.
- The group is selected from cached project namespaces in Settings.

## Main User Flows

### Authentication

- Settings collect:
  - GitLab base URL
  - OAuth application ID
  - optional GitLab group
- OAuth uses a localhost callback server with PKCE.
- Tokens are stored locally in Keychain.
- Base URL, OAuth client ID, and group selection sync via iCloud key-value storage.

### Assigned Issues

- Assigned issues are fetched from GitLab REST.
- Recently tracked issues are pinned first.
- Remaining issues are ordered by GitLab `updated_at` descending.
- The issue list hides scroll indicators.

### Time Tracking

- Starting an issue creates an active local tracking session.
- Tracking state (including away gaps) persists across app restarts and is restored on relaunch.
- **Non-blocking check-ins:** every checkpoint (default 20 min) the app posts a check-in notification and keeps tracking. There is no pause — missing the notification never loses time. The notification offers *Keep Tracking* or *Stop & Book*.
- **Booking happens on stop**, not per checkpoint. The booked total is: confirmed time + the in-progress interval + any away periods the user chose to count.
- **Away detection and reconciliation:** `ActivityMonitor` watches system/display sleep, screen lock/unlock, and fast user switching. When the machine becomes unavailable the clock freezes; on return tracking resumes automatically. A real absence (≥ 90 s) becomes an undecided `AwayGap` the user resolves as *Count as Work* or *Don't Count* — via a notification and an in-card banner that stays open until resolved. Sub-90 s blips count as continuous work. App downtime between launches is treated the same way.
- **Network resilience:** if a booking fails for a transient reason (offline/VPN down, 5xx, 429, auth blip) it is saved as pending and retried automatically with exponential backoff, and immediately when the network returns or the machine wakes. Permanent failures (e.g. 403/404) stay pending for manual retry.
- **Connection status:** `TrackingManager.connectionStatus` (`ConnectionStatus`) reflects whether the app can actually reach GitLab — derived from configuration, auth, network reachability, and the outcome of real API calls (an HTTP response means reached; a transport error means not). It surfaces as a colored dot on the menu bar icon and a status row in the popover, toggled by the `Show GitLab connection status` setting. The amber `gitLabUnreachable` state is the "network up but VPN/GitLab down" case.
- See `TRACKING_REFACTOR_PLAN.md` for the full design and rationale.

### Project Selection and Issue Creation

- Projects are fetched from GitLab and cached locally.
- The project selector is a searchable overlay list in the menu bar window.
- Recent projects are shown first.
- If a GitLab group is selected in Settings, only projects within that group are shown in the create flow.
- Creating an issue can optionally assign it to the current user.
- `Cmd+Enter` creates the issue.

## Key Files

- `My GitLab Timetracking/My_GitLab_TimetrackingApp.swift`
  - app entry point
  - menu bar app setup
- `My GitLab Timetracking/MenuBarViews.swift`
  - menu bar UI
  - issue list
  - create issue UI
  - searchable project selector
- `My GitLab Timetracking/TrackingManager.swift`
  - assigned issue refresh
  - issue ordering
  - session lifecycle (non-blocking check-ins)
  - away-gap accounting and reconciliation
  - time booking + automatic retry sweep
- `My GitLab Timetracking/ProjectManager.swift`
  - project loading and caching
  - selected project state
  - issue creation
- `My GitLab Timetracking/GitLabAPI.swift`
  - GitLab REST requests
- `My GitLab Timetracking/GitLabAuthManager.swift`
  - OAuth flow
  - token refresh
  - current user loading
- `My GitLab Timetracking/AppSettings.swift`
  - user defaults
  - iCloud sync
  - selected group / recent items
- `My GitLab Timetracking/SettingsView.swift`
  - settings UI
- `My GitLab Timetracking/SessionStore.swift`
  - persisted active tracking session
  - `AwayGap` model (undecided / counted / discarded)
- `My GitLab Timetracking/ActivityMonitor.swift`
  - sleep / display-sleep / lock / user-switch → away/return events
- `My GitLab Timetracking/NetworkMonitor.swift`
  - reachability (NWPathMonitor) for automatic booking retry and connection status
- `My GitLab Timetracking/ConnectionStatus.swift`
  - derived GitLab connection state shown in the menu bar / popover
- `My GitLab Timetracking/ProjectCacheStore.swift`
  - cached GitLab projects
- `My GitLab Timetracking/NotificationCoordinator.swift`
  - check-in notifications and away-gap reconciliation prompts
- `My GitLab Timetracking/OAuthCallbackServer.swift`
  - local OAuth callback listener

## Build Command

Use this from the repository root:

```sh
xcodebuild -project 'My GitLab Timetracking.xcodeproj' -scheme 'My GitLab Timetracking' -derivedDataPath /tmp/MyGitLabTimetrackingDerivedData CODE_SIGNING_ALLOWED=NO build
```

## Expected Working Style

- Keep commits small and focused.
- Do not reintroduce issue status handling unless explicitly requested.
- Prefer preserving the current menu bar UX instead of replacing it with a standard macOS window flow.
- Be careful with existing user changes in the worktree.

## Asset Files

- The app icon lives in `My GitLab Timetracking/Timetracker Logo.icon/` and uses the Xcode `.icon` format (not the legacy `.appiconset` format).
- The SVG source inside the `.icon` directory is extremely large. Do not attempt to read, parse, or validate it.
- Treat the entire `.icon` directory and its contents as opaque binary assets — do not modify or regenerate them unless explicitly asked.

## Useful Notes for Future Agents

- GitLab project data includes both display names and `path_with_namespace`.
- Group scoping should use `path_with_namespace`, not the display name.
- The app currently uses REST for projects, issues, and time booking.
- OAuth redirect URI is defined in `GitLabAuthManager`.
- If a future change touches project selection, re-test keyboard navigation in the project search field.
