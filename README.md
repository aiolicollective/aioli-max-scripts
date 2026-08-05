# aioli-max-scripts

Tools we build for our own 3ds Max work at the [/ai.oli](https://github.com/aiolicollective)
collective, and keep in one place so they stay usable, updatable and shareable.

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

Everything is designed around **one clone you can `git pull`**, rather than
copies scattered across machines.

### Recommended — clone into the Max user scripts folder

```bat
cd "%LOCALAPPDATA%\Autodesk\3dsMax\2026 - 64bit\ENU\scripts"
git clone https://github.com/aiolicollective/aioli-max-scripts.git aioli
```

Adjust `2026` to your version. You end up with:

```
…\ENU\scripts\aioli\
├── clonelayers\aioli-clonelayers.ms
├── ratiomask\aioli-ratiomask.ms
└── sunpos\aioli-sunpos.ms  (+ the Python modules)
```

To update later: `git pull` in that folder. Nothing else to do.

This location is what lets the `clonelayers` toolbar button find its script
again after a restart — see *Toolbar buttons* below.

### Otherwise

Clone or download the repo anywhere, and drag the `.ms` you need into a 3ds Max
window when you need it. Nothing is installed, nothing is written outside Max's
own preferences.

---

## Use

**Drag the `.ms` into a 3ds Max window** (or `Scripting > Run Script…`). The
panel opens. That is the whole story for a one-off.

### Toolbar buttons

Running a script once registers a macro under the **`aioli`** category. To get a
permanent button: `Customize > Customize User Interface…` > **Toolbars** tab >
Category **`aioli`** > drag the action onto a toolbar. The same actions are
available in the Menus, Quads and Keyboard tabs.

How each button behaves across restarts and `git pull` differs, and it is worth
knowing:

| Tool | Survives a Max restart | Follows `git pull` |
|---|---|---|
| **clonelayers** | yes, if the repo is cloned at `…\ENU\scripts\aioli\` | yes |
| **sunpos** | yes — the path to the clone is baked into the macro when you drag the `.ms` in | yes |
| **ratiomask** | yes | **no** — the macro holds a snapshot of the code, so re-run the `.ms` once after a pull that changed it |

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
row in the table above.

Conventions we hold to:

- **The repo is in English**, docs and code alike. Public repo, shared tools.
- One macro category, `aioli`, for every tool.
- Scripts named `aioli-<tool>.ms`, so they stay recognisable once they land in a
  user's Max folders.
- No write to render settings, no write to the source scene beyond what the tool
  is explicitly for. Everything wrapped in a single undo.
- Design decisions and traps already hit go in the tool's `NOTES.md` — that file
  is what stops the next person (or the next AI) from undoing a fix on purpose.

---

Written by the /ai.oli collective, with AI assistance. We say what is generated
and by whom.

MIT licence — see [LICENSE](LICENSE).
