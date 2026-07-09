# SquatchMail Dashboard Design Spec

*Synthesized from Refero references: **Felt** (felt.com — dark forest-toned SaaS command center), **San Rita** (sanrita.ca — expedition field-journal: chartreuse signal accent, monospace archival text, topographic motifs), and **Resend** (resend.com/emails — canonical email activity table layout). Do not copy any one wholesale; this spec is the synthesis.*

## Concept: "Field Research Station"

The dashboard is a wildlife-research command center. You are a cryptozoologist tracking elusive emails through the forest. Every email is a **Sighting**; every SES event is a **Footprint**; the suppression list is the **Do-Not-Disturb Registry**; the SES connection page is **Base Camp**; the activity feed is the **Trail Log**. UI copy leans hard into the theme (empty states, buttons, loading text); code module names stay boring (Email, EmailEvent, Suppression).

## Color tokens (CSS custom properties, prefix `--sq-`)

Light "daytime at the trailhead" theme, same as the landing page. The
palette is the landing page's main `@theme` block
(`landing-page/src/styles/global.css`): warm cream trail-map paper, deep
forest ink, pine-green signal. Keep the two files in sync when the palette
moves.

| Token | Value | Role |
|---|---|---|
| `--sq-bg-base` | `#f3efe0` | Deepest layer: page background (warm cream — trail-map paper) |
| `--sq-bg-surface` | `#faf7ec` | Level 1: cards, table container |
| `--sq-bg-raised` | `#e9e3cc` | Level 2: hovers, active nav, modals |
| `--sq-bg-highlight` | `#ded6ba` | Level 3: selected rows, inputs, chips |
| `--sq-text` | `#22301b` | Primary text (deep forest ink) |
| `--sq-text-muted` | `#67705a` | Secondary text, timestamps (muted green-gray) |
| `--sq-bark` | `#7d5f3c` | Warm bark brown — microlabels, table headers, field-journal annotations |
| `--sq-accent` | `#3e661f` | THE accent — pine-green signal. Links, active states, focus rings, live indicator |
| `--sq-chartreuse` | `#e2ffcc` | Radio-signal chartreuse — lives on the dark-pine button face, selection text |
| `--sq-btn-bg` / `--sq-btn-fg` | `#2c4419` / `#e2ffcc` | Primary button face: deep pine with chartreuse text (the landing `--btn-bg`/`--btn-fg` pair) |
| `--sq-accent-dim` | `#a39f7d` | Borders on interactive elements, ghost-button borders (sage) |
| `--sq-ember` | `#c06b2a` | Warm ember — warnings, complaint-rate gauge, "campfire" moments |
| `--sq-danger` | `#b23c2a` | Bounces, hard failures, destructive actions |
| `--sq-border` | `#ddd5b8` | Hairline 1px borders between rows/sections |

Status badge colors (badge = 1px border + tinted text, transparent bg, 4px radius):
sent `--sq-text-muted` · delivered `#4e7d2e` · opened `--sq-accent` · clicked `#257a67` · bounced `--sq-danger` · complained `--sq-danger` (filled) · rejected/failed `--sq-danger` · delayed `--sq-ember` · suppressed `--sq-text-muted` strikethrough.

## Typography

Same faces as the landing page, embedded as base64 woff2 `@font-face` rules
in `assets/css/fonts.css` (latin subsets; concatenated into the shipped
bundle by `mix squatch_mail.copy_css`) so the bundle stays self-contained —
no external font requests:

- **Display / page titles / wordmark**: `"Bebas Neue"` (fallback `"Arial Narrow"`), weight 400, uppercase, line-height 0.95, letter-spacing 0.02em — page titles like "TRAIL LOG", empty-state titles, the sidebar wordmark (`SQUATCH` + chartreuse `MAIL`).
- **Everything else**: `"Space Mono"` (400 + 700, fallback `ui-monospace, "SF Mono", Menlo, Consolas`) — body, tables, buttons, message IDs, timestamps, stat numbers. The landing page is mono-everywhere; the dashboard matches. 14px body, 12–13px data, letter-spacing -0.01em.
- ALL-CAPS mono microlabels (10–11px, `--sq-bark`, letter-spacing 0.14em) for section labels: `// TRAIL LOG`, `// FIELD REPORT`, `EXPEDITION 001` — the field-journal annotation feel.

## Layout (Resend blueprint, squatch skin)

- **Left sidebar** 220px, `--sq-bg-base`, 1px right border: logo (bigfoot mascot PNG, served content-hashed via the asset controller, + Bebas `SQUATCH`/pine-green-`MAIL` wordmark — same lockup as the landing page nav), nav sections with small outlined icons: Trail Log (activity), Sightings (sent), Bounces, Complaints, Do-Not-Disturb (suppressions), Base Camp (SES setup), Field Guide (docs link). Active item: `--sq-bg-raised` bg + `--sq-accent` left rail (2px).
- **Main panel**: page header row (serif title + live indicator + actions) → stat strip → filter bar (search input, date range, status dropdown, export) → data table.
- **Stat strip** ("Field Report"): 5 compact cards (`--sq-bg-surface`, 1px `--sq-border`, radius 6px, 12px padding): Sightings (sent), Delivery rate, Open rate, Click rate, Bounce rate — mono numbers 20px, muted delta vs prior period.
- **Activity table**: full-width rows, 1px `--sq-border` separators, no zebra. Columns: recipient+subject (two-line), status badge, engagement (footprint count icons: ◉ opens, ↗ clicks), timestamp (mono, relative). Row hover `--sq-bg-raised`. Click → inspector.
- **Inspector** (side sheet, 560px, `--sq-bg-surface`, slides over): "SIGHTING REPORT" header, rendered HTML preview in sandboxed iframe (plain white card), tabs: Preview / Text / Headers / Footprints (event timeline) / Raw. Timeline: vertical line with footprint icons per event, mono timestamps.
- **Radius**: 6px default (cards, inputs), 999px pills for primary buttons (Felt), 4px badges. **Shadows**: almost none — depth via surface levels (San Rita "no shadows" rule); single `rgba(0,0,0,0.2) 0 2px 5px` on modals/side sheets only.

## Bigfoot maximalism (the over-the-top layer)

- **Footprint iconography everywhere**: custom inline SVG footprint (5 toes + pad) used as: logo mark, event-timeline nodes, loading spinner (walking footprints animation — alternating left/right prints fading in), empty-state art, favicon, list bullets in docs.
- **Topographic background texture**: subtle SVG contour-line pattern (pine green at 10% stroke opacity, same paths as the landing page's `.topo`) on the trail-map-paper background — the San Rita map motif.
- **Live indicator**: pulsing chartreuse dot + mono label `TRACKING LIVE` (radio-signal vibe).
- **Empty states**: big footprint SVG + copy like *"No sightings yet. The forest is quiet… too quiet."* / suppressions: *"Nobody has asked to be left alone. The Squatch respects boundaries."*
- **Loading**: `FOLLOWING TRACKS…` mono text with animated footprints.
- **Copy voice**: field-journal terse. Buttons: "Log Sighting" (send test), "Re-track" (resend), "Break Camp" (disconnect SES). Errors: "The trail went cold: {reason}".
- **Header easter egg**: tiny sasquatch silhouette walks across the sidebar footer once per session (CSS animation, respects `prefers-reduced-motion`).
- **404/not-found**: "This sighting is unconfirmed. Probably a bear."

## Component rules

- Primary button: `--sq-btn-bg` (deep pine) bg, `--sq-btn-fg` (chartreuse) text, pill (999px), bold mono uppercase 12px. Hover: brightness 1.1.
- Secondary/ghost: transparent, 1px `--sq-accent-dim` border, `--sq-text`, radius 6px.
- Danger: 1px `--sq-danger` border ghost; filled only in confirm modals.
- Inputs/selects: `--sq-bg-highlight` bg, 1px `--sq-border`, radius 6px, focus ring `--sq-accent` 1px + subtle glow.
- Tables never scroll the page horizontally; the table container gets `overflow-x:auto`.
- Density: comfortable — 12px element gap, 24px section gap, 12px card padding (Felt).

## Accessibility

- Contrast: `--sq-text` on all surfaces ≥ 7:1; `--sq-accent` on `--sq-bg-base` ≥ 4.5:1; never `--sq-text-muted` under 12px.
- All status conveyed by badge text, not color alone. Focus visible on every interactive element. `prefers-reduced-motion` kills the walking squatch, pulse, and footprint spinner.
