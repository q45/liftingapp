# Release guide — Lifting

End-to-end checklist for getting this app onto TestFlight and then the
App Store. The order below is the cheapest-failure order: if something
is going to block you, it's better to find out at step 3 than step 18.

This doc is pragmatic and honest. It calls out the things in this
repo that are **not done yet** and must be finished before a public
submission. Skimming this first is worth an hour.

## Project snapshot (as of this commit)

| Item | Value |
|---|---|
| Bundle ID | `com.wasatchcode.lifting` |
| Marketing version | `1.0` (bump before each App Store submission) |
| Build number | `1` (bump before each TestFlight build) |
| Development team | `BDNFPW69WQ` (change if shipping from a different account) |
| Deployment target | iOS 26.4 |
| Signing | Automatic |
| Backend | Node/Express + Postgres, deploys to Fly.io (see `server/README.md`) |
| Auth | Sign in with Apple **(UI not yet implemented)** + Google ID Token exchange **(UI not yet implemented)**; server accepts both |
| AI | Server proxies to Anthropic; key lives in `server/.env` only |
| HealthKit | Not integrated |

---

## Pre-flight checklist

Go through this before anything else. Each unchecked item below is a
step you *must* do before a public App Store submission; most of them
block TestFlight too.

### Business / accounts

- [ ] Active Apple Developer Program membership ($99/yr) on the team
      that owns bundle ID `com.wasatchcode.lifting`.
- [ ] Agreements, Tax, and Banking sections in App Store Connect are
      complete (required before review, even for free apps).
- [ ] A working email + support URL the app can point users at for
      help (can be a Notion page or GitHub Pages site — see step 3).
- [ ] A hosted privacy policy URL (App Store rejects without one).
- [ ] Decision on pricing: free, paid, or free with IAP (this repo has
      no IAP yet; picking paid/IAP later means a separate surface).

### Repo readiness — must-fix before public submission

- [ ] **Sign in with Apple is required by App Store guidelines 4.8 if
      you offer any other third-party sign-in.** This repo has server
      endpoints for both Apple and Google, but **the iOS sign-in UI is
      not yet built** (see `server/README.md` Phase 2 section, and the
      comment at `lifting/AuthManager.swift:84`). Either:
    - Implement the Sign-in sheet calling Apple/Google and exchanging
      the identity token with `POST /auth/apple` or `/auth/google`, OR
    - Remove the Google exchange endpoint and ship Apple-only.
- [ ] `DEV_BYPASS_AUTH` must be **unset** on the production Fly.io
      server (it's an explicit dev escape hatch in
      `server/src/middleware.ts`; leaving it on means anyone can
      impersonate the legacy user).
- [ ] Default server URL in `lifting/DataLayer.swift:498` points to
      `http://localhost:3000`. For release builds this needs to be
      your production URL (e.g. `https://lifting-server.fly.dev`). See
      step 5 for the recommended approach (build-setting injection or
      simply changing the literal).
- [ ] App icon generated and dropped into
      `lifting/Assets.xcassets/AppIcon.appiconset/` as a single
      1024×1024 PNG (Xcode 14+ / iOS 17+ generates the smaller sizes
      automatically). See `marketing/app-store-design-prompt.md`.

### Repo readiness — nice-to-have before submission

- [ ] HealthKit integration (write workouts + sync body weight). Not
      required, but strongly recommended for a gym app and notably
      smooths App Review. Skipping is fine for v1; can land in 1.1.
- [ ] Crash reporting. Nothing is wired today. Sentry / Bugsnag /
      Crashlytics pick one. For v1 you can ship without and rely on
      Apple's Organizer crash logs.
- [ ] Onboarding flow. Not strictly required; your Coach tab nudges
      users to fill in the profile already.

---

# Part 1 — Back-end must be live

**Why first:** the app is useless without the server. Once this is
done and the URL is stable, everything else points at it.

Follow the full walkthrough in
[`server/README.md`](./server/README.md) (section "Deployment —
Fly.io"). Summary of what you produce by the end:

1. A Fly.io app deployed with a stable HTTPS URL:
   `https://lifting-server-<yourhandle>.fly.dev`.
2. A managed Postgres (Supabase or Neon) with its connection string
   set as the `DATABASE_URL` Fly secret.
3. `JWT_SECRET`, `APPLE_BUNDLE_ID`, `GOOGLE_OAUTH_CLIENT_ID_IOS`, and
   `ANTHROPIC_API_KEY` set as Fly secrets.
4. `DEV_BYPASS_AUTH` is **NOT** set.
5. `curl https://<your-app>.fly.dev/health` returns
   `{"ok":true,"db":"up"}`.

Keep the URL handy — you'll paste it into the app's default base URL
and App Store Connect support URL fields.

---

# Part 2 — Finish the must-fix repo items

Work through each unchecked item in the "Repo readiness — must-fix"
list above. The biggest one is **Sign in with Apple UI**. Rough shape
if you implement it:

1. New `SignInView.swift` with Apple + Google buttons.
2. Apple button: `SignInWithAppleButton` (SwiftUI). On success,
   extract `identityToken`, call
   `LiftingAPIClient.exchangeAppleIdentityToken(_:)`, store the
   returned session JWT in `AuthManager`, present the main tabbed UI.
3. Google button: requires the Google Sign-In SDK
   (`google-signin-ios`) via SwiftPM. On success, call
   `exchangeGoogleIdentityToken(_:)`. Same handoff.
4. Present `SignInView` whenever `AuthManager.currentSession == nil`.

`lifting/DataLayer.swift:409-425` already has the request/response
DTOs. The server side (`/auth/apple`, `/auth/google`) is done.

If you'd rather ship without Google, delete:
- The server's `/auth/google` route (`server/src/routes/auth.ts`)
- `GOOGLE_OAUTH_CLIENT_ID_IOS` from the env/secrets docs
- The `exchangeGoogleIdentityToken` method and Google button

---

# Part 3 — Hosting: privacy policy + support page

Required before App Store submission. Cheapest path:

### Option A: GitHub Pages (free, ~15 min)

1. Create a new public repo, e.g. `<username>/lifting-docs`.
2. Add a single `index.html` (or `privacy.html` + `support.html`).
3. Settings → Pages → deploy from `main` branch, `/` root.
4. Pages gives you `https://<username>.github.io/lifting-docs/`.

### Option B: Notion (free, ~10 min)

1. Create two public Notion pages: "Lifting Privacy Policy" and
   "Lifting Support".
2. Share → Publish → copy the public URLs.
3. The Notion URLs are ugly but work.

### What each page must contain

**Privacy Policy (non-negotiable minimum):**

- The name of the app and developer entity.
- What data you collect: email + name (Sign in with Apple/Google),
  workout data (sessions/exercises/sets), profile data (DOB year,
  height, body weight, experience, goal, equipment, notes).
- Where it lives: on-device (SwiftData) and your Fly.io server
  (Postgres).
- **The AI coach disclosure**: "Workout history, and when set, profile
  fields including body weight, may be sent to Anthropic's Claude API
  via our server to generate training recommendations. Anthropic does
  not train on this data per their enterprise API terms."
- What you do NOT do: no ad SDKs, no third-party analytics (if you
  later add one, update this), no selling health data.
- How to delete your data (currently: email the support address — add
  a real deletion endpoint in 1.1).
- Contact email.
- Effective date.

**Support Page (minimum):**

- App name.
- A "Contact Support" email link.
- FAQ section even if short (3–5 entries: "Is my data synced?", "How
  do I change units?", "How do I delete my account?").

Put these URLs somewhere safe. You'll paste them into App Store
Connect in Part 7.

---

# Part 4 — Generate launch assets

Use the two Claude prompts already in `marketing/`:

1. [`marketing/app-store-design-prompt.md`](./marketing/app-store-design-prompt.md)
   → feeds Claude the visual system and produces:
   - App icon concepts (1024×1024 PNG, no transparency, no pre-rounded
     corners — Apple rounds automatically).
   - Five 1320×2868 App Store screenshots (6.9" iPhone 16 Pro Max).
2. [`marketing/app-store-metadata-prompt.md`](./marketing/app-store-metadata-prompt.md)
   → produces App Store name, subtitle, description, keywords,
   What's New, category, age-rating answers, and privacy nutrition
   label answers.

### Icon

Drop the chosen 1024×1024 PNG into
`lifting/Assets.xcassets/AppIcon.appiconset/`. Xcode / iOS 17+ will
generate the smaller sizes automatically via the single-size icon
feature.

### Screenshots

- Apple accepts **1320×2868** (6.9" / 16 Pro Max) and auto-downscales
  for older display sizes. You do not need to produce 5.5" / 6.5"
  variants unless you want pixel-perfect smaller-device shots.
- Save finalized assets into `marketing/screenshots/01-*.png` …
  `05-*.png` so they live alongside the prompt they were made from.

### Copy

Save the Claude output to `marketing/copy/v1.0.md` for future
reference.

---

# Part 5 — Configure the Xcode project

### 5a. Bump the build number for TestFlight

Every upload to App Store Connect needs a unique build number within
a given marketing version. Options:

- **Manual**: Project → Lifting target → General → Identity →
  increment "Build" before each upload.
- **Automatic**: in Build Settings add `CURRENT_PROJECT_VERSION =
  $(GITHUB_RUN_NUMBER)` if using CI, or use a pre-archive script.

For the very first upload, `1` is fine.

### 5b. Point the app at production

Open `lifting/DataLayer.swift:498`. Change the default base URL:

```swift
return URL(string: "https://lifting-server-<yourhandle>.fly.dev")!
```

Better long-term: make it a build-config-driven setting so debug
builds hit `localhost` and release builds hit Fly.

```swift
#if DEBUG
return URL(string: "http://localhost:3000")!
#else
return URL(string: "https://lifting-server-<yourhandle>.fly.dev")!
#endif
```

### 5c. Remove the localhost ATS exception (if any)

Check `lifting.xcodeproj` and `Info.plist` settings for
`NSAppTransportSecurity` → `NSExceptionDomains` → `localhost`. If
present, **remove it for release builds** — Apple doesn't reject
because of it but it's a clear signal the app was half-shipped.

### 5d. Enable required capabilities

In Xcode → Target → Signing & Capabilities, confirm or add:

| Capability | Required because |
|---|---|
| Sign in with Apple | Apple sign-in (required if you keep Google too, per Apple guideline 4.8) |
| HealthKit | Only if you're shipping Tier 1 HealthKit in v1 (not required) |

Automatic code signing will pick up the entitlement changes and
provision the app identifier in the developer portal for you.

### 5e. Add Info.plist usage strings

In Target → Info → Custom iOS Target Properties, add purpose strings
for anything that triggers a permission prompt. Minimum for this app:

| Key | Why |
|---|---|
| `NSHealthShareUsageDescription` | Only if HealthKit read is used |
| `NSHealthUpdateUsageDescription` | Only if HealthKit write is used |
| `NSUserTrackingUsageDescription` | Only if you ever add an ad SDK (don't) |

The app currently doesn't touch camera, microphone, location, photo
library, or contacts — no additional strings needed.

### 5f. Create an App ID in the Apple Developer portal

If you're using **Automatic** signing (you are — it's the default),
Xcode does this for you when you archive. If you hit a signing error,
go to
[developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers)
and create an explicit App ID for `com.wasatchcode.lifting` with the
Sign in with Apple (and HealthKit if used) capability checked.

---

# Part 6 — Create the App Store Connect record

Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
My Apps → `+` → New App.

Fill in:

| Field | Value |
|---|---|
| Platform | iOS |
| Name | e.g. "Lifting" (≤30 chars; must be unique on the App Store) |
| Primary language | English (U.S.) |
| Bundle ID | Pick `com.wasatchcode.lifting` (from step 5f) |
| SKU | Anything unique to you, e.g. `lifting-ios-001` (private, never shown) |
| User Access | Full Access |

Click **Create**. You now have a skeleton app record. The listing is
not live or public until you submit and it's approved.

---

# Part 7 — Archive + upload the first build

### 7a. Select the right scheme + destination

- Scheme: `lifting`
- Destination: **Any iOS Device (arm64)** (NOT a simulator)

### 7b. Archive

Product → Archive. This kicks off a Release build with code-signing
applied. First archive can take 5–10 min.

The Xcode Organizer window opens when done. If it doesn't, Window →
Organizer.

### 7c. Distribute to App Store Connect

1. Select the archive.
2. Click **Distribute App**.
3. Choose **App Store Connect**.
4. Choose **Upload**.
5. Accept defaults for signing and symbol upload (keep "Upload your
   app's symbols" ON — gives you symbolicated crashes).
6. Upload. Takes 5–10 min depending on network.

### 7d. Wait for processing

After upload, App Store Connect takes 10–60 min to process the build.
You'll get an email when processing finishes (or fails — common
failures are missing usage strings or ITMS-91053 "Missing API
declaration" issues; see Troubleshooting at the bottom).

---

# Part 8 — TestFlight

Once the build finishes processing in App Store Connect, go to your
app → TestFlight tab.

### 8a. Internal testing (you + up to 99 teammates)

1. Under **Internal Testing**, create a group (e.g. "Internal").
2. Add testers by email (they must have an Apple account added to
   your Developer team with App Manager / Developer / Admin role).
3. Select the build (should appear immediately once processed).
4. No review required. Internal testers get the build within 1–2 min.

Install the TestFlight app on test devices, accept the invite, tap
Install. Good for your own sanity checks.

### 8b. External testing (up to 10,000 testers)

1. Under **External Testing**, create a group (e.g. "Beta").
2. Add testers by email OR generate a public TestFlight link.
3. **First external build requires Beta App Review** — Apple reviews
   the first submission per version (usually 24 hours, can be
   longer). Subsequent builds for the same version skip review.
4. Fill out the **Test Information** section (required for external):
   - **Beta App Description** (public-facing, what testers should
     expect)
   - **Email** (who testers contact with feedback)
   - **Privacy Policy URL** (required, even for TestFlight external)
   - **Sign-in info** if your app is gated (N/A if you keep the
     Apple/Google sign-in easy)
   - **Test instructions / notes** (help reviewers know what to try)
5. Submit for Beta Review.

External testers get an email with a link. After install, they can
submit feedback via TestFlight → Send Beta Feedback, which ends up in
your App Store Connect inbox.

### 8c. What to test in TestFlight

Run through this before submitting to App Store review. Failing any
of these is cheaper to find here than at review.

- [ ] Fresh install on a real device.
- [ ] Sign in with Apple end-to-end (if implemented).
- [ ] Start a workout → add exercise → log 3 sets → finish → verify
      session appears in History.
- [ ] Save the session as a template → start a new workout from the
      template → verify it replays.
- [ ] Tap AI Coach → Get Recommendations → verify either a real Claude
      response OR the offline fallback with the "Offline suggestion"
      badge.
- [ ] Per-exercise coach button on an ExerciseCard → same.
- [ ] Profile screen → fill in some fields → Save → reopen → values
      persist.
- [ ] Log 3 body-weight entries → delete one → verify swipe-to-delete
      works and history shows only 2.
- [ ] Toggle units between lbs/kg in Profile → verify Home volume card
      + History sets + Workout set-logger all update.
- [ ] Kill app mid-workout → relaunch → verify you're still in that
      workout (SwiftData persistence).
- [ ] Airplane mode → log sets → re-enable network → verify sync push
      fires and the rows land on the server.
- [ ] Dark mode looks right everywhere (the app is dark-only by
      design; confirm nothing flickers).
- [ ] App icon shows correctly on the Home Screen.
- [ ] No debug prints (`print("…")`) visible on launch in the device
      console — these ship in release builds and are fine but a good
      audit catches any leaked secrets.

---

# Part 9 — Submit to the App Store

Once you're happy with TestFlight:

### 9a. Fill in the version page

App Store Connect → your app → App Store → `1.0 Prepare for
Submission`.

Paste answers from `marketing/app-store-metadata-prompt.md` output:

- [ ] Name (≤30 chars)
- [ ] Subtitle (≤30 chars)
- [ ] Promotional text (≤170 chars)
- [ ] Description (≤4000 chars)
- [ ] Keywords (≤100 chars)
- [ ] Support URL (step 3)
- [ ] Marketing URL (optional)
- [ ] Primary + secondary category (Health & Fitness seems right)
- [ ] Age rating — walk through the questionnaire, target 4+
- [ ] Screenshots (step 4)
- [ ] App icon (already in the build from step 5)

### 9b. App Privacy (the nutrition label)

App Store Connect → App Privacy → Edit. Walk through the
questionnaire. With the current feature set, here's roughly what the
truthful answers look like (verify against your own code):

- **Data collected that's linked to the user**:
  - Contact Info → Email address (Sign in with Apple/Google)
  - Contact Info → Name (Sign in with Apple)
  - Health & Fitness → Workouts, Body weight, Height
  - User Content → Custom notes (the profile "notes" field)
- **Used for**: App Functionality, Product Personalization (the AI
  coach)
- **Shared with third parties**: YES — Anthropic, for AI coach prompts
  (Health & Fitness + User Content). Document this accurately; lying
  here is the #1 cause of post-launch App Store privacy complaints.
- **Tracking**: No (you don't have any ad SDKs).

### 9c. App Review Information

- **Sign-in account**: a real account testers can use. Apple reviewers
  do NOT use their personal Apple IDs. Create a test account (or
  describe how they can make one in 30s — easier with Sign in with
  Apple).
- **Notes**: include any relevant context. For this app:
  > "Backend is a Node server on Fly.io. AI coach sends workout
  > history to Anthropic's Claude API via our server under standard
  > API terms. Server handles rate limiting and caching; API key
  > never touches the device. App gracefully falls back to an
  > on-device rule-based recommender when the network is unavailable."

### 9d. Version Release

- **Manually release this version** (recommended) — you click
  "Release" after approval, on your schedule.
- Or **automatic release** after approval.

### 9e. Submit

Click **Add for Review** → review the entire page once more → **Submit
for Review**. The build transitions to "Waiting for Review" → "In
Review" → "Pending Developer Release" or "Ready for Sale".

Review time is typically 24–48 hours at this point in the App Store's
history. Can be longer at peak times (December, major iOS launches).

---

# Part 10 — After approval

- Release the version (if you picked manual).
- Verify the listing loads at
  `https://apps.apple.com/app/id<your-app-id>` within 10–30 min of
  release.
- Install from the real App Store on a device with zero caches (try a
  device that never had the app).
- Tag the commit: `git tag v1.0.0 && git push --tags`.

---

# Post-launch roadmap (informational)

Not required for launch, but useful to know what's next:

1. **Sign in with Apple UI** (if skipped for 1.0). Currently blocking
   Google sign-in from being usable in parallel.
2. **HealthKit Tier 1** — write workouts, sync body weight. Huge
   polish win; ~1 day of work.
3. **Account deletion endpoint** — Apple requires this in-app within
   some grace period. Currently users can only delete by emailing
   support. Land this in 1.1 if not 1.0.
4. **Crash reporting** — Sentry / Bugsnag / Firebase Crashlytics.
5. **What's New** copy for 1.1, 1.2, etc. — keep it changelog-style
   and honest. "Fixed X, improved Y" beats "Enhanced your experience".

---

# Troubleshooting common rejection reasons

App Review rejects 30–40% of first submissions. Common issues for
this app category:

| Symptom | Likely cause |
|---|---|
| "Guideline 4.8 — Sign in with Apple required" | You offered Google sign-in but not Apple. Add Apple or remove Google. |
| "Guideline 5.1.1 — Purpose string missing / unclear" | Your HealthKit / notification / other permission prompt didn't explain *why* in the Info.plist usage string. Rewrite specific and user-facing ("Log workouts to Apple Health") not internal ("HKWorkout use"). |
| "Guideline 2.1 — App incomplete" | Reviewer couldn't sign in, couldn't find a feature, hit a crash. Provide working test credentials + step-by-step reproduction notes. |
| "Guideline 5.1.1 (v) — account deletion" | You must offer in-app account deletion if you offer account creation. Implement before submission. |
| "Guideline 3.1.1 — In-app purchase required" | Only relevant if you sell digital goods. N/A for this app's current scope. |
| "ITMS-91053 Missing API declaration" | iOS 17+ requires declarations for certain "required reason" APIs in `PrivacyInfo.xcprivacy`. Xcode will usually scream about this during archive. If not, add an empty `PrivacyInfo.xcprivacy` to the target resources with the categories your app actually uses (file system `UserDefaults` is almost certainly one). |
| Binary rejected for missing icon sizes | Re-check `lifting/Assets.xcassets/AppIcon.appiconset/`. If you're using the single-size 1024×1024 feature, deployment target must be iOS 17+. Ours is 26.4, so you're fine. |
| Rejected for vague privacy nutrition label | Redo App Privacy with brutal honesty. Easier than arguing with the reviewer. |

---

# Quick reference — the minimum viable submission

If you want to ship ASAP and don't care about niceties:

1. [ ] Backend deployed + healthy (`server/README.md`)
2. [ ] Sign in with Apple UI built (Apple-only; skip Google for 1.0)
3. [ ] App points at production URL (`DataLayer.swift:498`)
4. [ ] `DEV_BYPASS_AUTH` is unset in Fly secrets
5. [ ] App icon added (1024×1024 PNG)
6. [ ] Privacy policy + support page hosted
7. [ ] 5 screenshots generated and uploaded
8. [ ] App Store Connect metadata filled in
9. [ ] Archive → Upload → TestFlight internal test → TestFlight
       external (beta review) → Submit for App Store review.

Realistic calendar time from "nothing done" to "Ready for Sale":
**2–3 weeks**, of which most is Apple review latency and you waiting
for TestFlight testers to kick tires. Actual engineering on the repo
items above is ~3–5 focused days.
