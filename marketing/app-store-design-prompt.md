# App Store design prompt — Lifting

Paste the prompt below into a fresh Claude conversation
(Claude Sonnet 4.5 or Opus, with image generation / artifact support)
to generate the app icon and App Store screenshots.

Keep this file updated if the app's visual identity changes — the
prompt hard-codes the color palette and component styles from
`lifting/Theme.swift`, so any drift there should be mirrored here.

---

I'm shipping an iOS app called **Lifting** to the App Store and need
you to design (1) an app icon and (2) a set of App Store screenshots.
Generate these as high-resolution images following the specs below
exactly.

## The app

**Lifting** is a minimal, local-first iOS workout tracker for people
who lift weights seriously. It:

- Logs workout sessions, exercises, and sets with a fast, thumb-
  friendly UI.
- Persists offline with SwiftData and syncs to a Postgres backend.
- Includes an **AI Coach** (powered by Claude) that recommends your
  next workout and gives per-exercise programming based on your
  history, goal, and units (lbs/kg).
- Has 4 tabs: **Home**, **Workout**, **History**, **AI Coach**.
- Target users: 25–45, serious but not pro lifters, who want
  Strong/Hevy-style logging without the bloat.

## Visual identity (non-negotiable)

- **Background:** near-black `#0C0C0C` (not pure black)
- **Card surfaces:** `#181818` and `#242424`
- **Borders:** `#2A2A2A`, 1px
- **Primary accent:** electric yellow `#F5E642` — used sparingly for
  the primary CTA, active state, and brand moments
- **Text:** white `#FFFFFF` primary, `#999999` secondary,
  `#666666` tertiary
- **Status:** green `#4ECB71` success, red `#FF4444` error
- **Category dots** (for exercise categories, in the screenshots):
  - Chest: `#FF6B6B` · Back: `#4ECDC4` · Legs: `#45B7D1`
  - Shoulders: `#96CEB4` · Arms: `#FFD166` · Core: `#C77DFF`
- **Type:** SF Pro (system font). Bold for numbers and section
  headers, medium for body, uppercase tracking for labels.
- **Corners:** 14pt radius on cards, 12pt on secondary buttons, 10pt
  on inputs.
- **Aesthetic:** disciplined, dark-room-gym, typographically
  confident. Not neon, not fitness-bro, no gradients, no photoreal
  muscle imagery. Think Linear / Arc / Things 3 rendered in a squat
  rack.

## Deliverable 1 — App Icon

Produce a single **1024×1024 PNG, no transparency, no pre-rounded
corners** (Apple rounds automatically). Also produce a 200×200
preview for my review.

Direction:

- **Mark:** a stylized dumbbell or barbell plate glyph, constructed
  from bold geometric shapes. Avoid literal photo-gym imagery. Mono-
  line or flat-shape, not skeuomorphic.
- **Background:** solid `#0C0C0C` OR a subtle near-black radial that
  stays dark.
- **Glyph color:** the electric yellow `#F5E642`. Optionally one
  secondary accent (white or muted gray) but keep it simple.
- **Must read clearly at 60×60px** (Home Screen size) — no thin
  strokes, no tiny detail.
- No text in the icon. No "AI" branding. No gradients. No drop
  shadows.
- Give me **3 distinct concepts** as separate 1024×1024 files so I
  can pick.

For each concept, write one sentence on the visual metaphor.

## Deliverable 2 — App Store screenshots

Generate **5 screenshots** at **1320×2868 px** (iPhone 16 Pro Max,
6.9" — Apple's current largest required size). Each must be a full-
bleed composition combining a **marketing headline** + **subheadline**
at the top and a **mock screen** of the app below, rendered in a
device-less "floating UI" style (no Apple-supplied device frame; the
UI sits on the branded background with subtle inner shadow).

Frame structure for every screenshot:

- Top 35%: dark background (`#0C0C0C`) with a big bold headline in
  white + shorter subheadline in `#999999`. Optional small yellow
  accent element (a dot, underline, or chip).
- Bottom 65%: a mock of the relevant app screen, cropped to show the
  hero interaction, with a soft inner glow of the yellow accent
  behind it for depth.
- Very slight film grain / subtle noise on the background to avoid
  looking flat.

Screenshot content (in order — these become the App Store carousel):

1. **"Log sets as fast as you can rack the bar."**
   Sub: "One-tap set logging. No modals. No scrolling."
   Mock: the **Workout** tab mid-session — exercise "Bench Press", 3
   sets logged (e.g. 185×5, 185×5, 185×4), the next set row
   highlighted with the yellow accent, a big "LOG SET" primary button
   at the bottom.

2. **"Your coach reads every rep you've ever done."**
   Sub: "Claude-powered recommendations based on your actual history."
   Mock: the **AI Coach** tab showing a generated recommendation card
   — "Next workout: Upper Push" with 4 exercises listed, target
   sets/reps, a short rationale paragraph, and a refresh button.

3. **"Progressive overload, visualized."**
   Sub: "Every lift tracked. Every PR surfaced."
   Mock: the **History** tab showing a list of past sessions with
   colored category dots, volume numbers, and a small trend chart at
   the top (bars climbing gently).

4. **"Built for offline. Synced when you're back."**
   Sub: "SwiftData locally. Postgres in the cloud. Never lose a set."
   Mock: the **Home** tab showing today's planned session, a "resume
   workout" card, and 3 stat cards (This week / Volume / Streak) using
   the `StatCard` style from the app.

5. **"Sign in once. Your data follows you."**
   Sub: "Sign in with Apple or Google. Zero passwords."
   Mock: a clean sign-in sheet centered on the dark background, with
   an Apple button (white on black) and a Google button (white card),
   "Lifting" wordmark above in white with a small yellow dot.

All screenshot mocks should use the exact component style from the
description:

- `StatCard`: dark `#181818` card, 14pt radius, 1px `#2A2A2A`
  border, 24pt bold white value, 11pt `#999999` sub-label.
- Primary CTA: full-width, 14pt radius, `#F5E642` background, bold
  black text, vertical padding 16pt.
- Section labels: 11pt uppercase, 1.0 kerning, `#999999`.
- Category dots: 8pt circle in the category color, followed by 15pt
  white medium-weight exercise name.

## Output format

For each deliverable:

1. Describe the concept in 2–3 sentences before generating.
2. Generate the image.
3. List the exact file dimensions and color palette used, so I can
   verify.

Do the icon concepts first, wait for my pick, then produce the
screenshots using the chosen icon's visual language.
