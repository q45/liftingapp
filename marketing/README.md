# marketing/

Prompts and assets for the App Store submission of **Lifting**.

## Files

- [`app-store-design-prompt.md`](./app-store-design-prompt.md) —
  prompt to give Claude to generate the 1024×1024 app icon and
  five 6.9" (1320×2868) App Store screenshots. Hard-codes the
  color palette and component styles from `lifting/Theme.swift`,
  so update this file if the app's visual identity changes.

- [`app-store-metadata-prompt.md`](./app-store-metadata-prompt.md)
  — prompt to give Claude to produce every text field App Store
  Connect asks for: name, subtitle, description, keywords,
  What's New, category, age rating, privacy nutrition label,
  and support/marketing URLs.

## Suggested workflow

1. Run the **design prompt** in Claude. Pick an icon concept, get
   the five screenshots (or draft the screenshots in Figma using
   Claude's written composition briefs).
2. Export:
   - `AppIcon-1024.png` → drop into `lifting/Assets.xcassets/
     AppIcon.appiconset/` (Xcode will generate the smaller sizes
     automatically for iOS 17+).
   - `screenshot-1.png` … `screenshot-5.png` (1320×2868) → upload
     to App Store Connect.
3. Run the **metadata prompt** in Claude. Paste the outputs into
   App Store Connect → your app → App Information / Version 1.0.
4. Host the privacy policy + support page somewhere permanent
   (GitHub Pages or a simple Notion page is fine).
5. Submit for review.

## Save the final assets here

Once generated, commit the chosen assets into this folder so the
repo is the single source of truth for the submission:

```
marketing/
├── app-store-design-prompt.md
├── app-store-metadata-prompt.md
├── icon/
│   ├── AppIcon-1024.png
│   └── concepts/            # other icon drafts for reference
├── screenshots/
│   ├── 01-log-sets.png
│   ├── 02-ai-coach.png
│   ├── 03-history.png
│   ├── 04-home.png
│   └── 05-sign-in.png
└── copy/
    └── v1.0.md              # finalized App Store copy
```
