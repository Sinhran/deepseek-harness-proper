# Design

## Theme

Warm paper light, warm near-black dark. Physical scene: a developer in a
normally lit room or a dim evening room, reading code for long stretches.
Both themes are first-class and switch live. Dark is a true warm black,
not a lifted gray.

## Color Palette

Tokens live in `Sources/dsh/Theme.swift` as dynamic `NSColor` values
(light-first, dark-second). Neutrals are tinted toward the warm brand hue.

| Role | Light | Dark | Used for |
| --- | --- | --- | --- |
| `bgBase` | `#F5F4F0` | `#050505` | Window, chat, inspector |
| `bgLayer1` | `#FCFBF9` | `#0E0D0A` | Raised layer |
| `bgLayer2` | `#FFFFFF` | `#161511` | Cards, composer, approval |
| `sidebarFill` | `#EFEEE9` | `#0B0A07` | Sidebar, settings nav |
| `labelPrimary` | `#16150F` | `#F7F6F2` | Body text |
| `labelSecondary` | `#5B5952` | `#B9B7B0` | Secondary text, icons |
| `labelTertiary` | `#908E87` | `#908E87` | Meta, timestamps |
| `labelCaption` | `#ABA99F` | `#6B6960` | Placeholders, chevrons |
| `accent` / `brandBlue` | `#2563EB` | `#60A5FA` | Blue accent, insertion point |
| `infoFill` | `#60A5FA` | `#3B82F6` | Send circle |
| `ctaFill` | `#2563EB` | `#60A5FA` | Primary CTA (blue, light ink) |
| `warnTertiary` | `#FDF3DA` | `#2A2210` | Approval strip wash |
| `errorPrimary` | `#BA2723` | `#F0776D` | Errors, destructive hover |
| `successText` | `#2F9E44` | `#6FD08C` | Connected status |
| `borderL2` | black 8% | white 8% | 0.5pt hairlines, card strokes |

Color strategy: Restrained. Tinted neutrals plus one blue accent used for
primary actions, selection, and state only. State colors (error, warning,
success, info) are standardized, never decorative. Blue buttons always
carry light ink (`#FFFFFF` light, `#050505` dark) for contrast.

## Typography

- UI: macOS system stack (San Francisco), `-apple-system` equivalent via `T.ui(_:_:)`.
- Display: system serif (New York, Georgia fallback) via `T.serif`, reserved for the empty-state hero headline only. Never in labels, buttons, or data.
- Code: SF Mono via `T.mono`.
- Scale ratio 1.125-1.2. Body 14, secondary 13, meta 12, captions 11, code 11-11.5. Section headers 13 medium tertiary. Body line length capped for prose; data and diffs may run dense.

## Spacing & Elevation

8pt base grid. Stack gaps 8/12/16/22 by hierarchy, card padding 12-18,
section rhythm 14-16. Hairlines 0.5pt (`borderL1`/`borderL2`). Cards radius
12 (content, settings, approval), composer 16. Soft elevation: black
3-5% blur 12-16 offset -4. No nested cards.

## Components

- `ActionButton`: quiet rows (32h), panel rows/nav (36h), elevated chip
  (30h), CTA blue capsule (38h), primary ink capsule (34h), info circle,
  28px icon buttons, dock tabs. All states: default, hover wash, selected
  wash, disabled 40% alpha, focus ring drawn on first responder.
- `SelectChip`: 28px model/autonomy picker, chevron, hover wash, popup `NSMenu`.
- `SendButton`: 34px blue circle. Glyphs: up arrow (send), rounded square
  (stop), arc spinner (sending, paused under reduced motion).
- `InputBar`: composer card (`inputMajor`, radius 16) with editor,
  attachment chips (24px), toolbar (tools left, model plus send right).
  Focused card strokes accent.
- `MessageView`: user right-aligned bubble (radius 14, 10/16 padding, max
  525px or 82% column); assistant fish mark plus name header, reasoning
  disclosure, tool-step rows, markdown, code blocks with banner plus copy.
- Tool-step rows: the tool glyph stays for the row's life (status is the
  tint, errors swap to an alert glyph); title is verb plus file name, full
  path in the tooltip; durations hide under 100 ms, then "340 ms", "1.2s".
  File-writing steps carry a quiet accent "Review" link into the inspector.
- Icons: SF Symbols are aspect-fit into their square slot, never stretched.
- Turn actions (on the last assistant message of each completed turn, the
  official client's unit): Branch on every turn; Rewind on earlier turns;
  Regenerate on the latest. Bare tertiary glyphs, 26pt. The latest turn's
  row is always shown; earlier rows fade in on hover (opacity, never layout,
  so the transcript doesn't shift and VoiceOver always reaches them). None
  while a run is in progress. Rewind and Regenerate confirm in plain words:
  what is removed, which files are restored, which are left alone because
  they changed since, and that commands aren't undone.
- New session: a nav row with an accent glyph and ⌘N caption, not a filled
  CTA; the transcript stays the loudest thing on screen.
- `CodeBlockView`: banner wash with language plus copy, mono body, radius 12.
- `ApprovalView`: warn strip, detail card, Reject (filled) plus Allow (primary).
- `Pill`/`Badge`: status pills with dot, mono Preview badge on soft wash.
- `EmptyState`: symbol plus title plus one quiet subtitle; teaches the interface.
- `Surface`/`TintedView`/`HairlineView`: layer-backed primitives that
  re-resolve dynamic colors on appearance change.

## Layout

`NSSplitView` with sidebar, chat, and optional inspector. The sidebar is
220-360 (default 264) with nav, sessions, and footer; it toggles away
entirely. Narrow windows (below ~1024px) auto-collapse it. Chat is fluid
(reading column clamp 680, composer +32, cap 920), inspector 240-400
(default 300), its pane buttons in the top row. All pane widths persist across launches, and both dividers drag.
Settings: 210px nav plus 20px cards, no Done bar (changes apply live; close
with the window button or ⌘W). Chat header: the top row itself, breadcrumbs
left, status right.

One top row, and it is the header. The window carries a `.unifiedCompact`
`NSToolbar` (38pt; macOS centers the traffic lights in it) and every pane
runs up underneath it. Lights, the sidebar toggle, the chat breadcrumbs and
the inspector toggle share one centerline: nothing above the row, no rule
under it, content starts right below. The sidebar opens straight onto its
nav with no brand lockup (`SidebarViewController.showsLockup`); the brand
lives in the empty-state hero and the app icon.

Top-row controls are toolbar items pinned to the window's edges, so
opening or closing a pane never moves them; never put them in a pane header,
which slides with its pane. Sidebar: a toggle right after the traffic lights.
Inspector: no generic toggle; its four panes are direct buttons at the
trailing edge (Preview, Review, Terminal, Trace). Click one to open the
inspector on it, another to switch, the active one to close. The active
button carries the selected wash only while the inspector is open; Review
carries the changed-file badge whether the inspector is open or not. All are
bare glyphs in tertiary ink with a square hover wash, act on first click
like system titlebar controls, and the chat breadcrumbs inset past them
while a pane is closed. The View menu mirrors them (Toggle Sidebar ⌥⌘S,
Toggle Inspector ⌥⌘I reopens the last pane). The inspector itself has no
tab strip: its content starts right under the top row. Nothing else lives in the top row.

The menu bar is the full standard set: app menu (About, Settings, Services,
Hide trio, Quit), File, Edit, View, Window (Minimize ⌘M, Zoom, window
list), Help.

## Motion

150-250ms state feedback only. Pane show/hide slides in 180ms (ease-out
quart): the divider glides, the pane's content holds its width and clips,
the chat column and breadcrumbs follow every frame, and a toggle mid-slide
reverses from where it is. Instant under Reduce Motion. Hover washes are instant redraws. Loaders
pulse or spin unless the system requests reduced motion, then they render
static. No page-load choreography, no bounce, no elastic easing.

## Copy

Sentence case in surface UI, Title Case for macOS menu items. Short,
specific labels. Placeholders teach syntax (`/`, `@`). Errors name the
recovery path. No em dashes.
