# aioli-max-scripts

Custom tools the [/ai.oli](https://github.com/aiolicollective) collective builds for
itself and runs inside 3ds Max, on the productions where we use it. Kept in one place
so they stay usable, updatable and shareable.

Three tools so far. Each lives in its own folder with its own README.

| Tool | What it does |
|---|---|
| [**clonelayers**](clonelayers/) | Clones a selection and rebuilds the whole layer / sub-layer tree of the sources, with a prefix, a suffix or an auto-incremented number. |
| [**ratiomask**](ratiomask/) | Viewport matte that previews any crop ratio (16:9, 9:16, 4:5…) without ever touching the render settings. Render 1:1, crop later. |
| [**sunpos**](sunpos/) | Places a sun at the real sun's position for a location, date and time, taking the scene's north rotation into account. NOAA maths, no time zone guessing. |

`clonelayers` and `ratiomask` are pure MaxScript, single file, no dependency.
`sunpos` is a Python panel (`pymxs` + PySide) and ships as a folder.

---

## Install

```bat
git clone https://github.com/aiolicollective/aioli-max-scripts.git
```

Anywhere you like — a tools folder, a synced drive, wherever. Nothing gets copied
into 3ds Max, and nothing is written outside Max's own preferences.

Then, **once per tool**: drag its `.ms` into a 3ds Max window (or
`Scripting > Run Script…`). The panel opens, and a macro is registered under the
**`aiolicollective`** category.

| Tool | File to drag in |
|---|---|
| clonelayers | `clonelayers/aioli-clonelayers.ms` |
| ratiomask | `ratiomask/aioli-ratiomask.ms` |
| sunpos | `sunpos/aioli-sunpos.ms` |

To update later: `git pull` in the clone. That is all — the buttons keep pointing at
the same files and pick the new version up on the next click.

---

## Toolbar buttons

`Customize > Customize User Interface…` > **Toolbars** tab > Category
**`aiolicollective`** > drag the action onto a toolbar. The same three actions are
available in the Menus, Quads and Keyboard tabs.

| Category | Action | Macro |
|---|---|---|
| `aiolicollective` | `clonelayers` | `aioli_clonelayers` |
| `aiolicollective` | `ratiomask` | `aioli_ratiomask` |
| `aiolicollective` | `sunpos` | `aioli_sunpos` |

All three behave the same way, on purpose:

- **The button survives a restart of 3ds Max.** Max writes the macro into its own
  `usermacros` folder and re-reads it on startup.
- **The button follows `git pull`.** Each macro is a thin launcher holding the path
  to its file in the clone, baked in when you drag the `.ms` in. It never carries a
  copy of the code, so a pull is enough.
- **Move the clone and the button breaks** — the baked path no longer resolves. You
  get an explicit message saying so; drag the `.ms` in once more and it is fixed.

Uninstalling a button means deleting the matching `.mcr` in
`%LOCALAPPDATA%\Autodesk\3dsMax\<version> - 64bit\ENU\usermacros\`.

---

## Compatibility

Written for **3ds Max 2026**, tested there.

`clonelayers` only uses stable, non-deprecated API (`layermanager`,
`maxOps.cloneNodes`, native `rollout` UI) and should run on 2016 and up.
`ratiomask` needs a Nitrous viewport. `sunpos` needs Python 3 with `pymxs` and
PySide6, with an automatic fallback to PySide2 on older versions.

Renderer-agnostic throughout: none of these tools touch render settings.
`sunpos` moves whichever sun you point it at — V-Ray Sun, Corona Sun, native
target light or free directional.

---

## Status

All three are **v1.0**. `clonelayers` and `ratiomask` are in production use.
`sunpos` has 47 automated tests covering the maths and the CLI, but its `pymxs`
layer has not been exercised in Max yet — see
[`sunpos/NOTES.md`](sunpos/NOTES.md) for the exact list of what is still to be
checked.

Issues and pull requests welcome.

---

## Contributing

Each tool folder is self-contained; adding a fourth means adding a folder and a
row in the tables above.

Conventions we hold to:

- **The repo is in English**, docs and code alike. Public repo, shared tools.
- One macro category, `aiolicollective`, for every tool. Action named after the
  tool, macro named `aioli_<tool>`, file named `aioli-<tool>.ms` — so a tool is
  recognisable wherever you meet it.
- **The macro is a launcher, never a copy of the code.** Bake the path in with
  `getSourceFileName()` at registration time, the way all three do. That is what
  keeps `git pull` meaningful.
- No write to render settings, no write to the source scene beyond what the tool
  is explicitly for. Everything wrapped in a single undo.
- Design decisions and traps already hit go in the tool's `NOTES.md` — that file
  is what stops the next person (or the next AI) from undoing a fix on purpose.

---

Written by the /ai.oli collective, with AI assistance. We say what is generated
and by whom.

MIT licence — see [LICENSE](LICENSE).
