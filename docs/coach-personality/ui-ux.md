# UI and UX

The personality system uses **progressive disclosure**. Picking a preset takes one tap on the Settings page. Everything else lives one level deeper, on a dedicated page. Every control comes from the existing tactile kit, so the UI works in Classic, Backrooms and both Denia themes without new tokens.

| Level | Where | What |
| --- | --- | --- |
| 1 · Pick | Settings > **AI Coach** card | preset grid, active profile, one-line description, "Customize" |
| 2 · Tune | **Coach personality** page (`/settings/coach`) | sliders, preferences, identity, instructions, preview |
| 3 · Manage | same page, **Profiles** section | create, rename, duplicate, delete, import, export, generate |

## Settings card

A new `CoachPersonalityCard` sits right after `ThemePickerCard` in `SettingsScreen` (one added line, like the Theme card). It mirrors that card's layout so the two read as a pair.

```text
┌─ ◎ AI Coach ─────────────────────────────────────────── [Customize ›] ┐
│                                                                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
│  │    ✦     │ │    ▣     │ │    ☺     │ │    ϟ     │ │    ◉     │      │
│  │ Default  │ │Professnl │ │ Friendly │ │Efficient │ │Intellect.│ ...  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
│   (selected KeyCap is pressed in)                                      │
│                                                                        │
│  Mentor · Patient and educational. Builds your game step by step.      │
│  ┌ Preview ─────────────────────────────────────────────────────────┐  │
│  │ You  Why do my smashes keep going into the net?                  │  │
│  │ ◎    Your swing has good speed, which is a great base. The net…  │  │
│  └──────────────────────────────────────────────── [Technique|Setback]┘ │
│                                                                        │
│  My profiles:  (● Footwork bootcamp)  (○ Weekend fun)  [+ New]         │
└────────────────────────────────────────────────────────────────────────┘
```

- **Grid.** A `Wrap` of `KeyCap`s, one per preset (icon and label), keyed `ValueKey('coach-preset-${id}')`, with `semanticLabel: '${label} coach personality'` and `tooltip:` set to the one-line description. On phones the width is 104, on wider screens 136, the same as the theme keys. The 17 keys wrap to 4 rows on a phone. A "Show all / Show fewer" toggle shows 8 by default on compact width, so the card stays short.
- **Description line** under the grid, updated on selection, in `bodySmall`.
- **Preview.** A sunken well (`InsetBox`, `app/lib/ui/depth.dart`) holding two bubbles that reuse `CoachBubble` styling, plus a `DepthSegmented` to switch between scenario A and B. The text is the static sample, so it changes instantly with no network call.
- **Profiles row.** `ChoiceChip`-style `KeyCap`s for saved profiles (up to 3 shown, then "+2 more"), plus "+ New". Tapping one activates it.
- **Customize** in the card's `trailing` slot opens the page.
- **Backend support.** If `/health` lacks `coach_personality`, the card shows a `StatusPill` "This server uses the standard coach voice" and disables the grid.

Selecting a preset **applies immediately**: it is saved, the next chat answer uses it, and a `SnackBar` reads "Coach is now Mentor" with an **Undo** action. This follows the Theme card, where a tap also applies at once.

## Coach personality page

Route `Routes.coachPersonality = '/settings/coach'`. Built with `PageScaffold(title: 'Coach personality')`. Compact width uses one column; expanded width (≥ 1024) uses two columns, with the editor on the left and a sticky preview on the right.

### Phone (compact)

```text
┌──────────────────────────────────┐
│ ‹  Coach personality      [Save] │  Save is enabled only with unsaved changes
├──────────────────────────────────┤
│ Profile  [Footwork bootcamp ▾]   │  dropdown: profiles + built-in presets
│ Based on Bold · edited           │
│                                  │
│ ┌ Preview ─────────────────────┐ │
│ │ (sample reply bubbles)       │ │
│ │ [Technique | Setback]        │ │
│ └──────────────────────────────┘ │
│                                  │
│ ▸ Personality      2 changes     │  collapsible sections (ExpansionTile style
│ ▸ How the coach talks            │   on RaisedTile); first open by default
│ ▸ Names                          │
│ ▸ Your instructions              │
│ ▸ Describe it, AI drafts it      │
│ ▸ Profiles                       │
│                                  │
│ [Restore Bold defaults]          │
└──────────────────────────────────┘
```

### Personality section (sliders)

```text
 Warmth                       45 · Moderate   ↺
 ├──────────────●──────────────────────────┤
        Bold default: 45

 Empathy                      60 · Moderate   ↺   ← changed: accent rim, reset visible
 ├──────────────────────●──────────────────┤
        Bold default: 55

 Assertiveness               100 · Dominant
 ├─────────────────────────────────────────●┤
   "Firm, never harsh."                         ← guard hint (attributes.md)
```

- One `Slider` per attribute: 0–100, `divisions: 20` (step 5). A label shows the value and band. A small "default" tick marks the preset value on the track.
- **↺ reset** is an `IconButton` with tooltip "Reset Empathy to 55". It is visible only when the value differs.
- A "2 changes" counter appears on the section header, plus **Reset all sliders**.
- Guard hints from the [attributes table](attributes.md#interactions-and-guards) appear under the slider that triggers them.

### How the coach talks (preferences)

One `DepthSegmented` per enum when it has 5 or fewer values (response length uses a dropdown with 6). Each segment has a `tooltip` with the rendering text from [communication-preferences.md](communication-preferences.md):

```text
 Response length   [ Adaptive ▾ ]
 Explanation       [Beginner|Intermediate|Advanced|Expert|Auto]
 Emoji             [None|Minimal|Moderate|Frequent]
 Humor style       [ Adaptive ▾ ]
 Pushback          [Supportive|Balanced|Skeptical|Challenging]
 Initiative        [Reactive|Balanced|Proactive]
 Emotion           [Restrained|Natural|Expressive]
 Language          [ Same as my messages ▾ ]
```

### Names

These are text fields for the coach's name (24 characters), the pronouns (a dropdown) and the player's nickname (24 characters), plus an "Address me by name" switch (`TactileSwitchTile`). A checkbox "Use for all profiles" maps to the `global` identity.

### Your instructions

```text
 Tell the coach how to talk (optional)
 ┌────────────────────────────────────────────┐
 │ Be strict about footwork. Call my backhand │
 │ "the problem child".                       │
 └────────────────────────────────────────────┘
                                     52 / 1000
 Preferred words  [kill ×] [clear = lob to the back ×] [+]
 Avoid words      [+]
 Catchphrases     [+]
 ⓘ Style only. The coach's rules, data and safety don't change.
```

A multi-line `TextField` with a counter and chip lists for vocabulary. If the text trips an injection heuristic, an inline warning appears under the field ("Parts of this look like instructions to change the coach's rules. They will be ignored."). Saving is still allowed.

### Describe it, AI drafts it

A text field (500 characters) and **Generate**, which opens the review sheet from [generator.md](generator.md#review-and-save). While it runs, the button shows a spinner and "Drafting…", the field is read-only and **Cancel** stays available. Errors show inline with **Try again** and **Draft without AI** (the local fallback).

### Profiles

```text
 ● Footwork bootcamp      Bold · edited      [⋯]
 ○ Weekend fun            Playful · edited   [⋯]   ⋯ = Rename · Duplicate · Export · Delete
 ○ Quiet Taskmaster  ✦AI  Stoic · edited     [⋯]
 [+ New profile]  [Import]  [Export all]
```

| Action | Behaviour |
| --- | --- |
| New | dialog: name + "start from" (any preset, or the current profile) |
| Rename | inline dialog; names unique, 1–32 characters |
| Duplicate | copies with " (copy)", not activated |
| Delete | confirmation dialog; deleting the active profile activates its base preset; **Undo** snackbar for 5 s |
| Activate | radio tap; same "Coach is now …" snackbar |
| Export / Import | [schema.md](schema.md#import-and-export) |
| Restore defaults | on a built-in-based profile: clears overrides, preferences and instructions after confirmation |

At most 20 profiles. At the limit, **New** is disabled with a tooltip explaining why.

## Save and apply behaviour

- **Settings card:** taps apply and save immediately, with Undo.
- **Customization page:** edits are a **draft**. The preview updates live, from static samples plus a "changed" badge. **Save** writes the profile and, if it is the active one, applies it from the next answer. **Back** with unsaved changes asks "Discard changes?". Sliders do not save on every drag, which avoids writing to `shared_preferences` dozens of times a second.
- **During a chat:** a personality change never interrupts a streaming answer. It applies to the next question. The chat shows a small divider, "Coach is now Mentor", so the change is visible in the history. Earlier messages are untouched.
- **Chat header:** the coach's name and the preset icon appear in the chat app bar. Tapping them opens a bottom sheet with the preset grid for a quick switch, without leaving the chat.

## States

| State | What the player sees |
| --- | --- |
| First run | Default selected; the card's description reads "Pick how your coach talks. You can change it any time." |
| Server without support | Grid disabled, pill "This server uses the standard coach voice", Customize still opens (profiles are local) |
| Coach off (`chat_available: false`) | Card still works (settings are local); generator offers only "Draft without AI" |
| Generating | Spinner on the button, Cancel available, other sections stay editable |
| Generator error | Inline error card with the server's message, Try again and Draft without AI |
| Validation error on save | Field-level error text (e.g., "Up to 24 characters"); Save disabled |
| Corrupt saved data | One-time `SnackBar` "Coach settings were reset because they could not be read" |
| Newer data version | Banner "These settings were made by a newer version of ShuttleSense. Changes are disabled." |
| Empty profiles | "No saved profiles yet. Change any setting to create one." |

## Accessibility

- **Touch targets** are 48 dp (`kMinTouchTarget`), as everywhere. `KeyCap` and `DepthSegmented` already comply.
- **Sliders** follow the [WAI-ARIA slider pattern](https://www.w3.org/WAI/ARIA/apg/patterns/slider/) through Flutter `Slider`:
  - `semanticFormatterCallback` reads "80, strong"; the attribute name is the label.
  - Arrow keys step by 5. A wrapper `Shortcuts`/`Actions` adds Page Up/Down (±20) and Home/End.
  - A hint is read on focus: "Default for Bold is 45".
- **Reset buttons** have tooltips that name the attribute and value.
- **Preview bubbles** carry `Semantics(label: 'Sample question' / 'Sample answer from Mentor')`, matching the chat's labels.
- **Changes** are announced with `SemanticsService.announce` ("Coach is now Mentor"), because the snackbar can be missed.
- **Keyboard order** goes top to bottom. Collapsible sections are buttons with expanded state, and Escape closes dialogs and sheets.
- **Text scaling** at 200% must not overflow. The grid wraps, and slider labels move above the track when the width is under 360 logical px.
- **Contrast:** all text uses existing tokens, which `test/skin_tokens_test.dart` holds to 4.5:1 in every theme. The "changed" accent rim uses `AppPalette` accent, which is held to 3:1.
- **Reduced motion:** no new animations beyond the kit's own, which already honour `MediaQuery.disableAnimations`.
- **Screen-reader users and emojis:** the coach's emoji preference defaults to the preset's. Playful's emojis are read aloud, so the description notes "uses emojis", and the emoji setting is one tap away.

## Themes

The UI adds no colours, images or painters. It works in all four themes because it uses only `SectionCard`, `KeyCap`, `InsetBox`, `RaisedTile`, `DepthSegmented`, `TactileSwitchTile`, Material `Slider` and `TextField`, which the theme builder already styles. Two checks follow from [THEMES.md](../THEMES.md):

- The `Slider` theme must be set in `AppTheme._build` from `TactileTokens`, because today only calibration and practice use sliders and their default Material colours may not reach 3:1 on the Backrooms wall. This is the one theme-builder change the plan needs, and it needs a review by the lead UI/UX developer.
- Decorated themes paint behind pages, and cards stay solid, so the page needs no special handling.

## Copy

- "Personality changes how your coach talks, not what it knows."
- "When you mention pain or something hard, every coach gets serious."
- "Style only. The coach's rules, data and safety don't change."
- "Your coach is an AI. It doesn't replace a qualified coach, doctor or physiotherapist." (shown once, under the grid)
