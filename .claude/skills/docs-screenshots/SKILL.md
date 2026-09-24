---
name: docs-screenshots
description: Capture or regenerate the terminal screenshots in docs/images for this repo (README and docs/reference.md). Use whenever a screenshot has to be added, refreshed after a UI change, or re-blurred — it drives the real cct TUI in a pty and renders the screen to PNG in the established style, with private data blurred out.
---

# Screenshots for the docs

Every image in `docs/images/` is one screen of the real TUI: `shots.py` runs
`cct` on a pty, types the keys that reach the screen, and renders the resulting
terminal buffer to a PNG. Nothing is mocked up, and no image editor is involved.

## Run it

```bash
python3 -m venv .venv && .venv/bin/pip install pyte pillow   # in your scratch dir
cd .claude/skills/docs-screenshots
<venv>/bin/python shots.py                    # list the catalogue
<venv>/bin/python shots.py time-by-project    # render one shot into docs/images/
<venv>/bin/python shots.py --dry menu         # capture and print the screen, render nothing
<venv>/bin/python shots.py --all
```

Each run prints the captured screen with row numbers. **Read that output before
accepting the PNG**: it tells you whether the keystrokes landed on the screen you
wanted, where the content ends (`rows` should leave the footer one or two lines
above the bottom), and whether anything private is still unmasked.

Two shots depend on local data:

- `CCT_SHOT_SESSION` / `CCT_SHOT_PROJECT` are typed into the picker's `/` filter
  (empty = the top row). For the time shots pick a session that has background
  agents, thinking and a dozen turns — it shows every row of the view.
- `export-prompts` runs a real export. It writes to `~/cct-export/<project>/` and
  refuses to overwrite, so delete that folder (or point `CCT_EXPORT_DIR` elsewhere)
  before re-running. Keep the default folder in the shot: the path is what the
  docs describe.

## Adding a shot

Add an entry to `SHOTS` in `shots.py`: the keys to press and the terminal size.

- Digits jump to a menu row (`"10"` = row 10), `enter` selects, `v` toggles the
  extended view, `"/text"` filters a picker, a bare number waits that many seconds.
- **Menu row numbers shift whenever an entry is added to the TUI** — check
  `ENTRY_ITEMS` in `cct` and re-run with `--dry` after any menu change.
- Arrow keys must be sent as `\x1bOB` etc. (`KEYS` in `shoot.py`) — curses puts the
  terminal in application-cursor mode, and a bare `\x1b[B` reads as Esc and quits.
- Reports need time to run: give the last key a `settle` of 8–12 s.
- `cols` is 118 for output views (→ 1212 px wide) and 100 for the menu, matching
  the images already in the repo. `rows` is both the terminal height and the image
  height; size it to the content.

Then reference the file from `README.md` (`docs/images/<name>.png`) or
`docs/reference.md` (`images/<name>.png`), with a one-line caption above it in the
voice of the surrounding text.

## Style — keep it identical across images

`shoot.py` fixes it: Menlo 16 px on `#16181E`, a 10 × 21 px cell grid, 16 px
padding, the palette of the terminal theme the first screenshots were taken in,
and `█` drawn as a filled cell so bar charts have no seams. Don't tune these per
image — a screenshot that differs in font, padding or blur is the one thing that
looks wrong on the page.

## Privacy — the rule for this repo

The repo is public. Project names and paths, session ids and titles, prompt text
and export folder names never appear in an image. `RULES` in `shots.py` is a list
of `(regex, group)` over each screen line; every matching range is **replaced with
filler letters and then blurred** (three passes of `GaussianBlur(6)`), so the
published PNG has no real text in it at all — not even under the blur. Spaces are
kept, which is what makes a blurred block look like blurred text.

What stays readable: dates, durations, token counts, costs, and the `(gone)` marker
— the numbers are the point of the screenshot.

When you add a shot, look at the printed screen line by line and add a rule for
anything private that no existing rule covers (a new column, a new header format).
A rule that matches nothing is harmless; a missing one leaks. If a name still shows
through, that image must not be committed.
