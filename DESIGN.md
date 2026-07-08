# SquatchMail Dashboard Design Spec

*Synthesized from Refero references: **Felt** (felt.com — dark forest-toned SaaS command center), **San Rita** (sanrita.ca — expedition field-journal: chartreuse signal accent, monospace archival text, topographic motifs), and **Resend** (resend.com/emails — canonical email activity table layout). Do not copy any one wholesale; this spec is the synthesis.*

## Concept: "Field Research Station"

The dashboard is a wildlife-research command center. You are a cryptozoologist tracking elusive emails through the forest. Every email is a **Sighting**; every SES event is a **Footprint**; the suppression list is the **Do-Not-Disturb Registry**; the SES connection page is **Base Camp**; the activity feed is the **Trail Log**. UI copy leans hard into the theme (empty states, buttons, loading text); code module names stay boring (Email, EmailEvent, Suppression).

## Color tokens (CSS custom properties, prefix `--sq-`)

Dark theme only for v1. Foundation from Felt, accent from San Rita.

| Token | Value | Role |
|---|---|---|
| `--sq-bg-base` | `#0f1509` | Deepest layer: page background ("midnight forest floor") |
| `--sq-bg-surface` | `#161b13` | Level 1: cards, table container (San Rita Forest Canopy) |
| `--sq-bg-raised` | `#212f0c` | Level 2: hovers, active nav, modals (Felt Deepest Green) |
| `--sq-bg-highlight` | `#2d3329` | Level 3: selected rows, inputs (San Rita Terrain Shadow) |
| `--sq-text` | `#dde2e4` | Primary text (Paper White) |
| `--sq-text-muted` | `#84907f` | Secondary text, labels, timestamps (Earth Gray) |
| `--sq-accent` | `#e2ffcc` | THE accent — "radio signal chartreuse". Links, active states, primary buttons (black text on it), focus rings, live indicator |
| `--sq-accent-dim` | `#64754b` | Borders on interactive elements, ghost-button borders (Muted Sage) |
| `--sq-ember` | `#dc8c46` | Warm ember — warnings, complaint-rate gauge, "campfire" moments (Felt Warm Ember) |
| `--sq-danger` | `#e0654f` | Bounces, hard failures, destructive actions |
| `--sq-border` | `#2a3324` | Hairline 1px borders between rows/sections |

Status badge colors (badge = 1px border + tinted text, transparent bg, 4px radius):
sent `--sq-text-muted` · delivered `#9ecf7a` · opened `--sq-accent` · clicked `#7adfcf` · bounced `--sq-danger` · complained `#e0654f` (filled) · rejected/failed `--sq-danger` · delayed `--sq-ember` · suppressed `--sq-text-muted` strikethrough.

## Typography

System stack only (self-contained assets, no font downloads):

- **Display / page titles**: `"Bebas Neue"`-style condensed feel is NOT available from system fonts — instead use `Georgia, "Times New Roman", serif` weight 400 at large sizes with tight line-height 0.95 (Felt's serif-authority move) for page titles like "TRAIL LOG".
- **UI / body**: `ui-sans-serif, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif`, 14px body, 12px captions, letter-spacing 0.02em.
- **Data / field-notes**: `ui-monospace, "SF Mono", Menlo, Consolas, monospace` — message IDs, timestamps, email addresses, headers, event payloads, stat numbers. The mono-everywhere-for-data is the San Rita signature; use it liberally. 12px, letter-spacing -0.01em.
- ALL-CAPS mono microlabels (10–11px, `--sq-text-muted`) for section labels: `// TRAIL LOG`, `// FIELD REPORT`, `EXPEDITION 001` — the field-journal annotation feel.

## Layout (Resend blueprint, squatch skin)

- **Left sidebar** 220px, `--sq-bg-base`, 1px right border: logo (footprint mark + SQUATCHMAIL wordmark), nav sections with small outlined icons: Trail Log (activity), Sightings (sent), Bounces, Complaints, Do-Not-Disturb (suppressions), Base Camp (SES setup), Field Guide (docs link). Active item: `--sq-bg-raised` bg + `--sq-accent` left rail (2px).
- **Main panel**: page header row (serif title + live indicator + actions) → stat strip → filter bar (search input, date range, status dropdown, export) → data table.
- **Stat strip** ("Field Report"): 5 compact cards (`--sq-bg-surface`, 1px `--sq-border`, radius 6px, 12px padding): Sightings (sent), Delivery rate, Open rate, Click rate, Bounce rate — mono numbers 20px, muted delta vs prior period.
- **Activity table**: full-width rows, 1px `--sq-border` separators, no zebra. Columns: recipient+subject (two-line), status badge, engagement (footprint count icons: ◉ opens, ↗ clicks), timestamp (mono, relative). Row hover `--sq-bg-raised`. Click → inspector.
- **Inspector** (side sheet, 560px, `--sq-bg-surface`, slides over): "SIGHTING REPORT" header, rendered HTML preview in sandboxed iframe (white card — the one light surface), tabs: Preview / Text / Headers / Footprints (event timeline) / Raw. Timeline: vertical line with footprint icons per event, mono timestamps.
- **Radius**: 6px default (cards, inputs), 999px pills for primary buttons (Felt), 4px badges. **Shadows**: almost none — depth via surface levels (San Rita "no shadows" rule); single `rgba(0,0,0,0.2) 0 2px 5px` on modals/side sheets only.

## Bigfoot maximalism (the over-the-top layer)

- **Footprint iconography everywhere**: custom inline SVG footprint (5 toes + pad) used as: logo mark, event-timeline nodes, loading spinner (walking footprints animation — alternating left/right prints fading in), empty-state art, favicon, list bullets in docs.
- **Topographic background texture**: subtle SVG contour-line pattern (2% opacity, `--sq-accent`) on the page background — the San Rita map motif.
- **Live indicator**: pulsing chartreuse dot + mono label `TRACKING LIVE` (radio-signal vibe).
- **Empty states**: big footprint SVG + copy like *"No sightings yet. The forest is quiet… too quiet."* / suppressions: *"Nobody has asked to be left alone. The Squatch respects boundaries."*
- **Loading**: `FOLLOWING TRACKS…` mono text with animated footprints.
- **Copy voice**: field-journal terse. Buttons: "Log Sighting" (send test), "Re-track" (resend), "Break Camp" (disconnect SES). Errors: "The trail went cold: {reason}".
- **Header easter egg**: tiny sasquatch silhouette walks across the sidebar footer once per session (CSS animation, respects `prefers-reduced-motion`).
- **404/not-found**: "This sighting is unconfirmed. Probably a bear."

## Component rules

- Primary button: `--sq-accent` bg, black text, pill (999px), mono uppercase 12px, px 16 py 8. Hover: brightness 1.06.
- Secondary/ghost: transparent, 1px `--sq-accent-dim` border, `--sq-text`, radius 6px.
- Danger: 1px `--sq-danger` border ghost; filled only in confirm modals.
- Inputs/selects: `--sq-bg-highlight` bg, 1px `--sq-border`, radius 6px, focus ring `--sq-accent` 1px + subtle glow.
- Tables never scroll the page horizontally; the table container gets `overflow-x:auto`.
- Density: comfortable — 12px element gap, 24px section gap, 12px card padding (Felt).

## Accessibility

- Contrast: `--sq-text` on all surfaces ≥ 7:1; `--sq-accent` on `--sq-bg-base` ≥ 12:1; never `--sq-text-muted` under 12px.
- All status conveyed by badge text, not color alone. Focus visible on every interactive element. `prefers-reduced-motion` kills the walking squatch, pulse, and footprint spinner.
