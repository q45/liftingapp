# App Store metadata prompt — Lifting

Paste the prompt below into a fresh Claude conversation to generate
all the text fields App Store Connect requires for submission.

Apple's field limits (as of 2026):

| Field | Max chars |
|---|---|
| App name | 30 |
| Subtitle | 30 |
| Promotional text | 170 (editable anytime, no review) |
| Description | 4000 |
| Keywords | 100 (comma-separated, no spaces after commas) |
| What's New (release notes) | 4000 |

---

I'm submitting an iOS app called **Lifting** to the App Store. Write
all the App Store Connect text fields for me, following Apple's
character limits and App Store Review Guidelines (no competitor
names, no unsubstantiated claims, no pricing in text, no emojis in
the app name/subtitle).

## About the app

**Lifting** is a minimal, local-first iOS workout tracker for serious
lifters who want Strong/Hevy-style logging without bloat.

Core features:

- **Fast set logging** — workout sessions, exercises, sets, RPE,
  with one-tap logging and thumb-friendly UI.
- **SwiftData-backed, offline-first** — every set persists locally
  the moment it's entered. Kill the app mid-workout and your data
  survives. Syncs to a Postgres backend in the background.
- **AI Coach powered by Claude** — recommends your next workout and
  per-exercise programming based on your actual history, goal, and
  units (lbs/kg). Cached so repeat requests are instant.
- **Sign in with Apple or Google** — zero passwords, data
  synced across devices.
- **Exercise library** organized by category (Chest, Back, Legs,
  Shoulders, Arms, Core) with custom exercise support.
- **History + PR surfacing** — every lift tracked, every session
  reviewable, volume and streak stats.
- **Plate calculator** for fast bar math.
- **Templates** for repeatable workouts.

Target users: 25–45, serious but not pro lifters. People who've
outgrown a notes app but find MyFitnessPal / Fitbod / Strong either
too cluttered or too prescriptive.

Tone of voice: confident, dry, disciplined. Never "crush your goals",
never "unleash your potential", never "gym bro". Think the copy on
Linear, Things 3, or Arena Club — dry, specific, a little witty.

## Deliverables (produce each clearly labeled)

### 1. App name (≤30 chars)

Produce 3 options. The leading candidate is simply **Lifting** but
suggest alternatives that would work if "Lifting" is taken on the
App Store. None may use Apple's product names.

### 2. Subtitle (≤30 chars)

Produce 5 options. The subtitle appears directly under the app name
in search and on the product page — it's your #1 chance to sell the
app in a glance. Use strong nouns/verbs. Examples of good subtitles:
"Tasks and to-dos, beautifully" (Things), "The reading app"
(Readwise).

### 3. Promotional text (≤170 chars)

One paragraph. This can be updated anytime without App Review —
treat it as the "what's new this month" billboard. Keep it
announcement-flavored.

### 4. Description (≤4000 chars)

Structure:

- **Opening 2-line hook** — what the app is and who it's for.
  Must land without a subhead.
- **Paragraph 2** — the core thesis (offline-first, AI-backed, no
  bloat).
- **Features section** — bullet list using the `•` character, 6–10
  bullets, each one short + concrete (not "Track workouts" but
  "Log a set in two taps, no modals").
- **"Built different" section** — 1 paragraph on what makes it
  unlike Strong / Hevy / Fitbod, without naming them.
- **Privacy paragraph** — data stays on device, syncs only to your
  own account, AI requests proxied through our server (Anthropic
  key never on device), no ads, no tracking SDKs.
- **Closing line** — one-sentence call to open the app and log a
  first set.

Do not use hyperbole ("best ever", "revolutionary", "ultimate").
Do not mention competitors. No emojis in the description.

### 5. Keywords (≤100 chars, comma-separated, no spaces after commas)

App Store search ranks on keywords + title + subtitle. Do not
repeat words that already appear in the title/subtitle — that's
wasted space. Prioritize high-intent, lower-competition terms over
generic ones like "fitness". Suggested seed list:
`workout,lifting,strength,sets,reps,gym,barbell,log,tracker,PR,
progressive,overload,routine,coach,AI`. Select the best subset
that fits in 100 chars.

### 6. What's New (≤4000 chars — for version 1.0 launch)

For 1.0, a concise "welcome" note is better than a changelog.
3–5 bullets on what ships in 1.0, written in the past tense as if
speaking to someone who just installed.

### 7. Category recommendations

Primary + Secondary App Store categories, with one-line rationale
each.

### 8. Age rating answers

Walk through Apple's age-rating questionnaire (violence, sexual
content, gambling, unrestricted web access, user-generated content,
etc.) and produce the answers appropriate for a workout tracker.
Goal is a **4+** rating.

### 9. Privacy nutrition label

Fill out Apple's App Privacy questions given these facts:

- The app collects **email** and **name** (from Sign in with Apple
  / Google) for account creation.
- It collects **workout data** (sessions, exercises, sets) linked
  to the user's account.
- It sends **workout history** to our own backend, which proxies
  anonymized prompts to Anthropic's Claude API. No third-party
  trackers. No ads SDKs. No analytics beyond crash reports.
- Data is encrypted in transit and at rest.
- Users can delete their account and all data.

Produce the exact selections for each question Apple asks.

### 10. Support + marketing URLs

Provide placeholder URLs I should register:

- Support URL (required)
- Marketing URL (optional)
- Privacy Policy URL (required)

Recommend a cheap, reputable way to host a simple Privacy Policy
+ Support page (e.g. a GitHub Pages site or a single Notion page).

## Output format

Produce each section as a clearly labeled markdown heading. For
length-limited fields, show the character count in parentheses after
each option. For options where you give variants, briefly (1 line)
explain why you'd pick the recommended one.
