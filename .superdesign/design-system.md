# Semantic native macOS search
System SF font only. Neutral native light/dark adaptive surfaces (popover material), subtle separators, single blue system selection accent. No gradient, mascot, logo, decorative illustrations, or heavy translucent text.

## Geometry (as shipped in Panel.swift / PanelRows.swift / FilePreview.swift)
- Window 900px wide (the inline preview needs the room), 22px continuous corner radius, 22px side insets for header/footer text, 8px for the list.
- Header 72px; search input 22px regular; quiet tertiary placeholder "Search files, apps, or ask…" ("Say what to do with it…" with a file attached).
- Summary line 30px under the header: result summary left (11.5px medium, secondary), scope/indexing status right (11px secondary). Indexing shows a 12px determinate ring and "Indexing 25/7,000 · ~2 min".
- Rows: file 64px with 32px icon; action/source row 46px with 22px icon (64px when it carries an excerpt). Title 15px medium (files) / 13px regular (actions); subtitle and match excerpt 12px secondary; matched words semibold in label colour (excerpts, from FTS « » marks) and bold in titles (typed words at word starts). Selection: rounded 10px, inset 4×2px.
- Right edge of a row: "↩" on the selected row, "Unavailable" / "…" when relevant, "⌘1…⌘9" while ⌘ is held. The kind tag only appears when the list has a single section.
- Section headers (Files, Apps, Actions, Web, Contacts, Events, Notes, Clipboard) 24px, 11px semibold secondary, non-selectable; shown only when a list mixes sections. Sections follow their best row, so the top result stays first.
- List with any file: list column 396px, 1px separator, preview column fills the rest; minimum list height 370px. The column stays for the whole result set; a non-file row shows a centred summary (icon, title, what Return does).
- Footer 36px with visible key hints for the selected row, "esc Close" right.

## Behaviour
- Five primary file results; a "Show all files" row (⌘↓) appears when the engine reports more.
- Stable selected result as asynchronous results arrive; while typing the previous rows stay (dimmed to 50% if new results take over 150 ms) and are inert: Return, Tab, drag, ⌘1–9 and preview buttons do nothing until results for the current text arrive. The panel never shrinks while typing.
- Height changes animate 0.12 s ease-out; row replacement crossfades 0.12 s; both are off with Reduce Motion.
- Hovering selects a row only when the pointer moves. ⇧↑/⇧↓ and ⇧-click select several files (Tab attaches all, ⌘↩ reveals all, drag drags all). ⌘K lists actions for the selected file(s). ⌥ shows the score breakdown in place of the subtitle.
- ↑ on an empty field recalls previous queries (last 50); reopening within 10 s restores the last search and selection.
- Subtitles show relative dates (Just now, 2 min ago, 3 hr ago, Yesterday, Mon, 12 Mar, 12 Mar 2025).
- Toasts: HUD pill, 13.5px medium, icon for success (green check) / problem (orange triangle) / spinner for sticky "Working…"; problems stay at least 6 s.
- Preview: matching PDF page (scrollable, matched words highlighted), image/document thumbnail, text scrolled to the first match, paused inline player for audio/video at the matched time; metadata line (pixels, pages, duration, size).
- Single search field, no complex navigation. Empty state minimal one-line help, no demo results in the real app. Explicit filter text visible. VoiceOver hears the result count once typing pauses.
