# lifting server

REST API for the `lifting` iOS app. Handles bidirectional sync of workout
data between SwiftData and Postgres, proxies AI coach requests to
Anthropic (so the Claude API key never lives on device), and brokers
Sign in with Apple / Google identity tokens into server-issued session
JWTs.

## Stack

- Node 20, Express 4, TypeScript (strict)
- Postgres 14+ (`pg` driver, handwritten SQL — no ORM)
- Zod for request/response validation
- `jose` for JWT sign/verify + provider JWKs
- `@anthropic-ai/sdk` for the coach endpoint
- `tsx` for dev-time hot reload

No SPM / CocoaPods / build tooling beyond `tsc`.

## Setup

```bash
# 1. Install dependencies
cd server
npm install

# 2. Copy .env.example to .env and fill in the required variables
#    (see "Environment variables" below)
cp .env.example .env

# 3. Create the database (one-time)
createdb lifting
#    or:   psql -c 'CREATE DATABASE lifting;'

# 4. Run migrations + start the server
npm run dev
# listens on http://localhost:3000
```

`npm run dev` runs `tsx watch`, which applies migrations then hot-reloads
on any file change. For a non-watching prod-like run, do `npm run build
&& npm start`.

## Environment variables

| Var | Required? | Purpose |
|---|---|---|
| `DATABASE_URL` | yes | Postgres connection string, e.g. `postgres://user@localhost/lifting` |
| `JWT_SECRET` | yes | >=32 char random string. Signs session JWTs. Generate: `node -e "console.log(crypto.randomBytes(32).toString('hex'))"` |
| `APPLE_BUNDLE_ID` | yes* | iOS bundle ID. Validated as the `aud` claim on incoming Apple ID tokens. *Required only if you want `/auth/apple` to work. |
| `GOOGLE_OAUTH_CLIENT_ID_IOS` | yes* | Google Cloud iOS OAuth 2.0 Client ID. Validated as the `aud` claim on Google ID tokens. *Required only if you want `/auth/google` to work. |
| `ANTHROPIC_API_KEY` | yes* | Required only for `/coach/*` endpoints. |
| `ANTHROPIC_MODEL` | no | Override the default coach model (default: `claude-sonnet-4-5`). |
| `COACH_CACHE_TTL_SECONDS` | no | Cache TTL for coach responses (default 3600). |
| `COACH_RECENT_SESSIONS` | no | Max recent sessions fed to the coach prompt (default 6). |
| `DEV_BYPASS_AUTH` | no | Set to `true` in dev to treat unauthenticated requests as the legacy user. Ignored when `NODE_ENV=production`. |
| `API_KEY` | no | Legacy shared-secret `X-API-Key`. Applied before session auth; kept around for ops tooling. |
| `CORS_ORIGIN` | no | Comma-separated allowlist. Defaults to `*`. |
| `PORT` | no | Defaults to 3000. |

## Endpoints

**Unauthenticated:**

- `GET /health` — liveness + Postgres ping
- `POST /auth/apple` — body `{identityToken}` → exchanges an Apple ID
  token for a session JWT. Returns `{accessToken, expiresAt, user}`.
- `POST /auth/google` — same, for Google ID tokens.
- `POST /auth/signout` — currently a no-op server-side (stateless JWTs).
  Client still calls it for integration symmetry.

**Authenticated** (`Authorization: Bearer <jwt>`; dev builds can bypass
via `DEV_BYPASS_AUTH=true`):

- `GET  /sync/changes?since=<ISO>` — delta pull, scoped to the caller.
  Returns every workout_session / exercise_entry / workout_set owned by
  the authenticated user that changed after the cursor plus `serverTime`
  for the next round.
- `GET|PUT|DELETE /workout-sessions/:id`
- `GET|PUT|DELETE /exercise-entries/:id`
- `GET|PUT|DELETE /workout-sets/:id`
- `POST /coach/recommendations` — body `{goal, unit, refresh?}` → full-
  workout recommendation.
- `POST /coach/exercise-recommendation` — body `{exerciseName, goal,
  unit, refresh?}` → single-exercise recommendation.

`PUT` endpoints are idempotent upserts using last-write-wins on
`updated_at` (server keeps its copy when its timestamp is newer) AND the
row's `user_id` must match the caller. `DELETE` is soft (flips
`deleted_at`, bumps `updated_at`) so offline clients learn about
deletions on their next pull.

## Schema

Auth tables:

- `users` — minimal profile (`id`, `email`, `name`, `is_legacy`).
- `auth_identities` — one row per `(provider, provider_user_id)`, FK to
  `users`. Splitting identities out of `users` means adding a third
  provider later never touches the `users` table.

Domain tables, all carrying `user_id NOT NULL REFERENCES users(id)` plus:

```
updated_at   TIMESTAMPTZ   -- last-write-wins cursor
deleted_at   TIMESTAMPTZ   -- soft-delete tombstone (NULL = live)
```

- `workout_sessions`
- `exercise_entries` (`session_id` FK, `ON DELETE CASCADE`)
- `workout_sets` (`exercise_id` FK, `ON DELETE CASCADE`)
- `coach_analyses` — cache of LLM recommendations; partitioned by
  `user_id` + `subject_id` so users can never see each other's cached
  results.

See `src/db.ts` for the definitive schema. Composite indexes of
`(user_id, updated_at)` back the per-user `/sync/changes` range scan so
performance stays constant regardless of how many users share the DB.

### Legacy user

A special user with id `00000000-0000-0000-0000-00000000fee1` is seeded
at migration time. Any pre-auth workout data is backfilled to own this
user. On the first real Apple/Google sign-in, `findOrCreateUserForIdentity`
(in `src/auth/users.ts`) claims this user — attaching the incoming
identity to it and flipping `is_legacy=false` — so existing data
silently becomes the first real user's. This only happens once;
subsequent sign-ins for other providers create fresh accounts (no
cross-provider linking).

## Auth architecture

```
iOS ──POST /auth/apple { identityToken } ─────▶ server
                                                │
                                                ▶ verify identityToken
                                                │   against Apple JWKs
                                                │   (issuer, audience, exp)
                                                │
                                                ▶ findOrCreateUserForIdentity
                                                │
                                                ▶ sign HS256 session JWT
                                                │
iOS ◀───────────── { accessToken, user } ──────┘

iOS ──GET  /sync/changes  ─────────────────────▶ server
    Authorization: Bearer <accessToken>         │
                                                ▶ verifySessionToken
                                                ▶ req.userId = user.id
                                                ▶ scope all queries
```

Session JWTs live 7 days. When expired, the client silently re-auths
with Apple (`ASAuthorizationAppleIDProvider.getCredentialState`) or
Google (`GIDSignIn.restorePreviousSignIn`) to get a fresh identity token
and exchanges it for a new session JWT. No refresh-token table.

## Caching (AI)

`coach_analyses` stores one row per `(user_id, subject_id)` tuple, where
`subject_id` is a deterministic UUID derived from the coach scope
(`"workout"` vs `"exercise"`) plus the relevant inputs (`goal`, `unit`,
and exercise name for the per-exercise endpoint). Lookups filter by
`expires_at > NOW()` so stale rows are ignored. TTL is controlled by
`COACH_CACHE_TTL_SECONDS` (default 1h). Pass `refresh: true` in the
request body to bypass cache on a single call.

## Production notes

- ATS exceptions on the iOS side (`Info.plist`) allow plain HTTP only
  to `localhost`/`127.0.0.1`. Put the server behind TLS (nginx / Caddy)
  before shipping and remove those exceptions.
- `DEV_BYPASS_AUTH` is ignored when `NODE_ENV=production`, but set it
  explicitly to `false` in prod `.env` anyway for defense in depth.
- No retry/backoff on failed LLM calls. If Anthropic returns a 5xx the
  caller sees it directly.
- Server-side signout is a no-op (stateless JWTs). If you ever need
  hard revocation (e.g. compromised token), add a short-TTL Redis
  blocklist checked in `verifySessionToken`.

---

# Deployment — Fly.io

The repo ships with a `Dockerfile`, `.dockerignore`, and `fly.toml` so
the server can be deployed to [Fly.io](https://fly.io) with no extra
plumbing. Postgres is hosted externally (recommended: Supabase or
Neon for truly managed Postgres — Fly's own Postgres is
unmanaged-you-own-the-backups).

## One-time setup (~15 min)

### 1. Install the Fly CLI & sign in

```bash
brew install flyctl         # or: curl -L https://fly.io/install.sh | sh
fly auth signup             # or: fly auth login
```

### 2. Provision a Postgres (pick one)

**Option A — Supabase (recommended):**

1. https://supabase.com → new project (free tier is fine)
2. Project Settings → Database → **Connection string** → **URI** (the
   "Transaction" pooler string on port `6543` is best for serverless-
   style workloads; `5432` direct is fine for always-on). Copy it.
3. It looks like:
   `postgres://postgres.xxxx:PASSWORD@aws-0-us-west-1.pooler.supabase.com:6543/postgres`

**Option B — Neon:**

1. https://neon.tech → new project, copy the pooled connection string
   (must include `?sslmode=require`).

Either way, append `?sslmode=require` to the connection string if it
isn't already there — the `pg` driver respects it automatically.

### 3. Launch the Fly app

From the `server/` directory:

```bash
# Edit fly.toml first: set `app` to something unique (e.g.
# `lifting-server-<yourhandle>`) and `primary_region` to the region
# closest to your users (`fly platform regions` to list them).

fly launch --no-deploy --copy-config
# Answers:
#   - Use existing fly.toml? yes
#   - Create Postgres cluster? NO (we're using Supabase/Neon)
#   - Create Upstash Redis? NO
```

`--no-deploy` means it creates the app + assigns a hostname but doesn't
try to deploy yet, so we can set secrets first.

### 4. Set secrets

`fly secrets` are encrypted env vars, available to the running app.
The values in `[env]` in `fly.toml` are *non-secret* only; secrets go
here.

```bash
fly secrets set \
  DATABASE_URL="postgres://...your-supabase-url...?sslmode=require" \
  JWT_SECRET="$(node -e 'console.log(crypto.randomBytes(32).toString(\"hex\"))')" \
  APPLE_BUNDLE_ID="com.wasatchcode.lifting" \
  GOOGLE_OAUTH_CLIENT_ID_IOS="...apps.googleusercontent.com" \
  ANTHROPIC_API_KEY="sk-ant-..."
```

Optional hardening:

```bash
fly secrets set CORS_ORIGIN="https://yourdomain.com"
# Do NOT set DEV_BYPASS_AUTH in prod. NODE_ENV=production ignores it
# anyway, but leaving it unset avoids confusion.
```

### 5. Deploy

```bash
fly deploy
```

First deploy takes ~2-4 min (builds the Docker image remotely). The
`migrate()` call in `src/index.ts` runs on every boot, so the schema
is created on first deploy automatically.

### 6. Verify

```bash
fly status                                    # app + machines health
fly logs                                      # live logs
curl https://<your-app>.fly.dev/health        # should return {"ok":true,"db":"up"}
```

## Day-to-day commands

```bash
fly deploy                      # ship a new version
fly logs                        # live tail
fly ssh console                 # exec into the machine
fly secrets list                # names only, values never shown
fly secrets unset VAR_NAME      # remove a secret
fly scale count 2               # run 2 machines (no cold starts + redundancy)
fly scale memory 1024           # bump RAM on existing machines
fly apps destroy <name>         # nuke the whole app
```

## Updating the iOS app

Once deployed, point the iOS app at the Fly hostname:

- `lifting/Networking/APIClient.swift` (or wherever `baseURL` lives) →
  `https://<your-app>.fly.dev`
- Remove the `NSAppTransportSecurity` localhost exceptions from
  `Info.plist` once you're no longer testing against `localhost`.

## Costs (rough)

- Fly: one shared-cpu-1x / 512MB machine with `auto_stop_machines =
  "stop"` costs ~$0-3/mo depending on traffic (scales to zero when
  idle). Expect one cold start every ~30-60 min of idleness — adds
  ~1-2s latency to the next request.
- Supabase free tier: 500 MB Postgres, 2 projects, sufficient for
  early development. Pro is $25/mo when you outgrow it.
- Total at rest: **~$0-3/mo** for a just-launched app.

If you want zero cold starts, set `min_machines_running = 1` in
`fly.toml`. That pins at least one machine on and costs ~$2-3/mo more.

## Portability out

Nothing here locks you in:

- `Dockerfile` works unchanged on Cloud Run, Railway, Render, ECS, or
  a plain VPS with `docker run`.
- Postgres is standard; `pg_dump` from Supabase/Neon, restore
  anywhere.
- Secrets → env vars, a one-liner to move.

The only Fly-specific file is `fly.toml` (~40 lines), which has
direct equivalents in any other platform's config.

---

# Phase 2 — iOS sign-in UI: external setup checklist

Phase 1 (server) is complete. Phase 2 adds the iOS `SignInSheet` with
Sign in with Apple + Google buttons. Before coding Phase 2, you must
complete the console setup below. None of this can be automated.

## Apple side (~15 min)

### 1. Register the App ID

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click **+**, select **App IDs**, Continue
3. Select **App**, Continue
4. Description: `Lifting`
5. Bundle ID: **Explicit** → `com.wasatchcode.lifting`
6. In Capabilities, check **Sign In with Apple** (leave "Enable as a primary App ID")
7. Continue → Register

### 2. Enable the capability in Xcode

1. Open `lifting.xcodeproj`
2. Project navigator → target **lifting** → **Signing & Capabilities** tab
3. Click **+ Capability** → search **Sign in with Apple** → add
4. With "Automatically manage signing" on, the provisioning profile
   regenerates itself.

### 3. Create the App Store Connect record

1. https://appstoreconnect.apple.com/apps
2. Click **+** → **New App**
3. Platform: **iOS**, Name: `Lifting`, Primary Language: English, Bundle
   ID: `com.wasatchcode.lifting`, SKU: `lifting-ios-001`
4. Create. Metadata can stay empty; the record just needs to exist.

## Google side (~20 min)

### 1. Create / pick a Google Cloud project

1. https://console.cloud.google.com/projectcreate
2. Project name: `lifting-ios` (any works) → Create
3. Wait ~10s, then select it in the project picker

### 2. Configure the OAuth consent screen

1. Left sidebar → **APIs & Services** → **OAuth consent screen**
2. User Type: **External** (unless you have Google Workspace). Create.
3. App name: `Lifting`, User support email: yours, Developer contact email: yours. Save and Continue.
4. Scopes: Save and Continue (defaults are fine — we only need `openid`, `email`, `profile`)
5. Test users: add your Gmail as a test user (required in testing mode). Save and Continue.
6. Back to Dashboard.

**Note:** the app starts in "testing" mode — 100 test-user cap and an
"unverified app" warning on first sign-in. Submit for verification
(~1 week review) before public launch.

### 3. Create the iOS OAuth client

1. Left sidebar → **APIs & Services** → **Credentials**
2. **+ CREATE CREDENTIALS** → **OAuth client ID**
3. Application type: **iOS**
4. Name: `Lifting iOS`
5. Bundle ID: `com.wasatchcode.lifting`
6. App Store ID: leave blank
7. Team ID: your Apple Developer Team ID (find at
   https://developer.apple.com/account → top right, "Membership details")
8. Create
9. From the dialog, save:
   - **Client ID** — e.g. `1234567890-abcdef.apps.googleusercontent.com`
   - **iOS URL scheme** — same string reversed, e.g. `com.googleusercontent.apps.1234567890-abcdef`
10. Click **Download PLIST** → save `GoogleService-Info.plist` (ignore
    the Firebase naming — it's the GoogleSignIn plist)

## Server `.env` updates

```bash
JWT_SECRET=<64-char hex from `node -e "console.log(crypto.randomBytes(32).toString('hex'))"`>
APPLE_BUNDLE_ID=com.wasatchcode.lifting
GOOGLE_OAUTH_CLIENT_ID_IOS=<Client ID from step 3.9>

# Keep this true until Phase 2 ships the iOS sign-in UI.
# Remove (or set false) once users can actually sign in.
DEV_BYPASS_AUTH=true
```

## Checklist before starting Phase 2 code

- [ ] Bundle ID confirmed (default: `com.wasatchcode.lifting`)
- [ ] Apple Dev portal App ID shows "Sign in with Apple" enabled
- [ ] Xcode Signing & Capabilities shows "Sign in with Apple"
- [ ] App Store Connect record exists
- [ ] Google Cloud OAuth consent screen published (testing mode OK)
- [ ] Google iOS OAuth Client ID created and noted: _________________
- [ ] iOS URL scheme noted: _________________
- [ ] `GoogleService-Info.plist` downloaded (I'll tell you where to drop it)
- [ ] Server `.env` updated with `JWT_SECRET`, `APPLE_BUNDLE_ID`, `GOOGLE_OAUTH_CLIENT_ID_IOS`
- [ ] `npm run migrate` has been run at least once (creates `users` + `auth_identities` tables, backfills existing data to the legacy user)

## Simulator gotcha

Sign in with Apple on the iOS Simulator is flaky (silent failures on
some iOS versions). **Test Apple sign-in on a real device.** Google
Sign-In works fine in simulator.
