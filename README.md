# lifting

SwiftUI workout tracker with SwiftData persistence, a Node/Postgres
sync server, and a server-proxied Claude AI coach.

```
/
├── lifting/            # SwiftUI iOS client (iOS 17+, Xcode 15+)
├── Info.plist          # dev-only ATS exceptions for localhost HTTP
├── lifting.xcodeproj/
└── server/             # Node 20 + Express + Postgres + Anthropic SDK
```

## Architecture at a glance

- **Local-first iOS.** SwiftData is the single read source for the UI.
  Views use `@Query`; never round-trip to the server for display.
- **Server as source of truth for writes.** Every local edit sets three
  sync fields on the `@Model` (`updatedAt`, `deletedAt?`, `needsSync`)
  and fire-and-forget calls `SyncEngine.shared.scheduleSync()`.
- **Last-Write-Wins** on `updatedAt`, enforced both client-side (skip
  merge if local is newer) and in SQL (`WHERE updated_at <=
  EXCLUDED.updated_at`).
- **Soft deletes** via `deletedAt` tombstones so offline devices learn
  about deletions on their next pull.
- **AI server-proxied.** iOS calls `POST /coach/recommendations`; the
  server builds the prompt, calls Claude, Zod-validates the JSON
  response, caches it in Postgres, and returns a structured DTO. The
  Anthropic API key lives only in `server/.env`.

## One-time setup

### Server

```bash
cd server
npm install
cp .env.example .env
# set DATABASE_URL + ANTHROPIC_API_KEY in .env
createdb lifting
npm run dev          # http://localhost:3000
```

See `server/README.md` for endpoint docs and schema details.

### iOS

1. Open `lifting.xcodeproj` in Xcode 15+.
2. Select an iOS 17+ simulator. Cmd-R.
3. On the AI Coach tab, tap the ⚙️ icon top-right:
   - **Server URL**: leave blank for `http://localhost:3000`, or set
     your Mac's LAN IP for testing on a physical device (e.g.
     `http://192.168.1.20:3000`).
   - **Server API key**: leave blank in dev unless you set `API_KEY` on
     the server.

Both values are stored in the iOS Keychain, not UserDefaults. The
Claude API key is never entered on-device — it lives in `server/.env`.

## Key files

### iOS client

| File | Role |
|------|------|
| `Models.swift` | `@Model` classes + `SyncTrackable` + `WorkoutManager` (SwiftData-backed, crash-safe active workout) |
| `DataLayer.swift` | Codable DTOs (mirror of server Zod schemas) + `LiftingAPIClient` |
| `SyncEngine.swift` | Singleton push/pull manager; LWW reconciliation |
| `KeychainHelper.swift` | Secure storage for server URL + X-API-Key |
| `ClaudeService.swift` | Thin facade over `LiftingAPIClient.coachRecommendations` |
| `liftingApp.swift` | Wires `ModelContainer`, `SyncEngine`, `WorkoutManager` |
| `WorkoutView.swift` / `CoachView.swift` / etc. | SwiftUI views |

### Server

| File | Role |
|------|------|
| `src/db.ts` | Pool + idempotent schema migrations |
| `src/schemas.ts` | Zod DTO schemas (mirror of Swift DTOs) |
| `src/mappers.ts` | Row ↔ DTO + hydration helpers |
| `src/routes/sync.ts` | `GET /sync/changes?since=...` |
| `src/routes/workoutSessions.ts` | Deep upsert + soft delete |
| `src/routes/coach.ts` | `POST /coach/recommendations` |
| `src/ai/analyze.ts` | Anthropic call + Zod validation + Postgres cache |
| `src/ai/prompts.ts` | System + user prompt builders |

## Sync lifecycle

1. **App launch** (`liftingApp.task`): hydrate `ModelContainer`, create
   `SyncEngine`, call `syncNow()` (push then pull).
2. **User edits**: views call `markDirty()` / `markDeleted()` on the
   model, save the context, then `SyncEngine.scheduleSync()`.
3. **Pull-to-refresh** (`HistoryView`): `await
   SyncEngine.shared?.syncNow()`.

`WorkoutManager` is rewired to persist the active workout immediately —
every set is written to SwiftData as it's logged. Killing the app mid-
workout no longer loses data; `WorkoutManager.init` recovers any
unfinished session on next launch.

## Known limitations / TODO

- Auth is a single shared secret (matches the F9 pattern). No
  multi-user support yet; to add, partition every table by `user_id`
  and switch to JWT sessions.
- No retry/backoff. Failed pushes stay dirty (`needsSync=true`) and
  retry on the next manual sync trigger.
- No WebSocket / SSE — pull-only, manual triggers.
- No streaming for coach responses. 3–8s wait is tolerable because
  calls are infrequent, but could be upgraded to streaming for snappier
  UX.

## Before shipping

- Replace localhost ATS exceptions in `Info.plist` with a TLS-fronted
  production URL.
- Set a strong `API_KEY` in `server/.env` and require it client-side
  (it's already wired; just populate in the Coach settings sheet).
- Rotate the Anthropic key via `ANTHROPIC_API_KEY` without deploying
  the client.
