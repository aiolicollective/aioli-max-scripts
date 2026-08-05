# sunpos — technical notes

> Handover note. Read this before picking the development back up. The
> [`README.md`](README.md) next to it is the usage doc; this file documents the
> design decisions. Please do not undo them without reading why they are there.

---

## File map

```
sunpos/
├── aioli-sunpos.ms      ← ENTRY POINT: drag this into 3ds Max
├── sunpos_max.py           PySide6 panel (pymxs). The heart of the tool.
├── sunpos_core.py          solar maths. pure stdlib, no dependency.
├── sunpos_zones.py         offline time zone table, DST included.
├── tzlookup.py             GPS → IANA zone (`auto` mode). Needs pip.
├── sunpos_cli.py           command line interface. OPTIONAL.
├── setup.bat / setup.sh    creates the folder's .venv. OPTIONAL.
├── run.bat   / run.sh      runs the CLI in that .venv. OPTIONAL.
├── requirements.txt        timezonefinder, tzdata
├── tests/test_sunpos.py    47 regression tests
├── README.md               usage doc
└── NOTES.md                this file
```

**Module dependencies** — the direction matters:

```
sunpos_core.py  ─┐
sunpos_zones.py ─┼─→ sunpos_max.py     (direct import, pure stdlib)
                 │        └─ subprocess ─→ tzlookup.py   (`auto` mode only)
                 └─→ tzlookup.py ─→ sunpos_cli.py
```

In practice: **deleting `sunpos_cli.py`, `run.*` and `setup.*` does not break the
Max tool** — only the `auto` time zone mode becomes unavailable, and `zone` plus
`manual` cover nearly every need. Conversely `sunpos_core.py` and
`sunpos_zones.py` are essential and must stay next to `sunpos_max.py`.

The CLI is kept because it lets the calculation be used outside 3ds Max (Blender,
Houdini, a batch script, a spreadsheet through `--json`), and because it is what
makes the test suite possible without launching Max.

---

## Design decisions (do not undo without a reason)

### One single source of truth for the maths

`sunpos_core.py` is imported as-is by the Max panel and by the CLI. The previous
version duplicated the calculation across both files, and the same bugs lived
there twice. A test (`test_max_tool_matches_core`) checks that both paths give
the same numbers to `1e-6`.

### DST is never guessed

Three modes, none of which improvises:

| mode | source | install |
|---|---|---|
| `zone` *(default)* | offline table, the chosen zone's published rule | none |
| `manual` | typed UTC offset | none |
| `auto` | IANA database via GPS | `setup.bat` once |

An old "PC" mode (the machine's own time zone) was **removed**: it gave a
plausible but wrong result as soon as the workstation and the site differed,
without the slightest signal. It also acted as a silent fallback when `auto`
failed.

**Do not reintroduce deriving the time zone from coordinates without border
data.** A "nearest city" heuristic gets it wrong near borders, and being an hour
out is worth ~15° of azimuth — exactly the kind of invisible mistake that was
eliminated.

### `auto` mode installs nothing into 3ds Max

Resolving an IANA zone needs `timezonefinder` **and** `tzdata` — on Windows,
`zoneinfo` has no zone database without `tzdata`. Running `pip install` into
Autodesk's Python risks breaking other tools in the pipeline.

So the panel **delegates that one question** to the Python in the folder's
`.venv`, running `tzlookup.py` as a subprocess and reading one line of JSON.
Result cached, `CREATE_NO_WINDOW` to avoid a console flash, 30 s timeout.

### The offline zone table is deliberately incomplete

`sunpos_zones.py` covers 34 zones. Every entry is cross-checked against `tzdata`
by the test suite, on 24 dates through the year. Zones whose rule a frozen table
cannot honestly follow are **absent** rather than approximated:

- `Africa/Cairo` — DST reintroduced in 2023, liable to change again
- `Africa/Casablanca` — suspended during Ramadan, which shifts every year
- `Asia/Jerusalem` — its own rule, revised several times

Those three were found **by the test**, not by rereading the code. If zones are
added, the test has to stay green.

### Atmospheric refraction, on by default

Light bends in the atmosphere: the direction the sun actually lights from is the
apparent one, not the geometric one. Measured on a 10 m building:

| geometric elevation | shadow without refraction | with |
|---|---|---|
| 0.5° | 1 146 m | **625 m (−45 %)** |
| 2° | 286 m | 251 m (−12 %) |
| 10° | 56.7 m | 56.2 m (−1 %) |
| 30° | 17.3 m | 17.3 m (0 %) |

Negligible high in the sky, decisive at golden hour — so precisely in the case
production cares about. Can be unticked in the panel, `--no-refraction` in the
CLI.

### Sun distance: free, and pinned to `z_max`

A physical sun emits **parallel rays**: only the reference→sun direction counts,
never the distance. It is chosen so that the day's culmination lands exactly at
`z_max` above the reference point — the whole path then stays under that ceiling
with **one single** distance for every sample. Never change the X:Y:Z *ratio* of
a position; multiplying it by a scalar, on the other hand, does nothing.

### Geometric conventions

3ds Max frame: `+X` right, `+Y` forward (north at rotation 0), `+Z` up. Azimuth
`Az` from true north, clockwise. Scene rotation `R` about Z:

```
X = target.x + D · cos(el) · sin(Az − R)
Y = target.y + D · cos(el) · cos(Az − R)
Z = target.z + D · sin(el)
```

Invariant checked by the tests: true north (`Az = 0`) lands on
`(−sin R, cos R)`. For `R = 5°` → `(−0.087, +0.996)`.

---

## Traps already hit — do not reintroduce them

Each one cost a round trip and is covered by a test.

1. **3ds Max module cache.** Max keeps a single Python session: after editing
   `sunpos_core.py`, `python.ExecuteFile` restarts the panel but reuses the
   **old** core, producing incomprehensible `unexpected keyword argument` errors.
   The panel therefore forces an `importlib.reload` — but **only inside Max**,
   because reloading a module replaces the class objects and would break the
   `except` clauses of any code that imported it earlier. A `CORE_VERSION` makes
   it fail cleanly if the folder is half updated.
2. **Qt's `autoDefault`.** In a `QDialog`, `Enter` fires the first button — so
   `Pick sun` — or closes the box. Neutralised with `setAutoDefault(False)` and a
   `keyPressEvent` that swallows `Enter`.
3. **Leftover animation keys.** Going from `path` to `single` left the keys in
   place: the sun looked placed, then moved again on scrub. The position
   controller is now replaced from scratch on every application. The tool *marks*
   the nodes it animates (`setUserProp`) so it never destroys a third party's
   animation without asking.
4. **Zones beyond UTC±12.** Sunrise/sunset was computed from local noon converted
   to UTC, which skips a day in Auckland (+13). It now starts from UTC midnight
   of the local civil date.
5. **Sunrise and sunset labelled "below the horizon".** The official sunrise
   threshold is −0.833° (refraction + disc radius), but the test was `el > 0`.
   Three states now: `above` / `on` / `below`.
6. **Algorithm blind to the year.** The old Spencer "fractional year"
   approximation gave an identical sun in 2021 and 2026. Replaced with the NOAA
   equations driven by the julian day.

---

## Still to check inside 3ds Max

The maths and the CLI are covered by 47 automated tests. The `pymxs` code,
however, was written against the API but **has not been run inside Max**. This is
the outstanding work on this tool.

1. `pymxs.undo(True, "sunpos")` — the two-argument signature is not documented
   everywhere; a fallback to `pymxs.undo(True)` is in place. Check that `Ctrl+Z`
   really undoes everything in one go.
2. `node.dir = normalize(ref − pos)` on a free directional — check the beam
   points at the reference. If it is inverted, the fix is one sign.
3. `rt.units.SystemType` — the returned string can vary by version; the
   `_CM_PER_UNIT` dictionary needs extending if the log says
   `system units '?' not recognised`.
4. `node.position.controller = Position_XYZ()` must actually clear the track on a
   V-Ray Sun. Careful: this wipes any rig on the sun.
5. `auto` mode on Windows: confirm no console flashes.
6. Drag & drop of the `.ms`, then a toolbar button surviving a restart.

---

## Open ideas

- Read the north rotation straight from the compass helper or the scene
  environment instead of typing it — that would remove the weak link in the
  accuracy chain.
- A mini-map location picker in the panel.
- A `tzfpy` backend (lighter than `timezonefinder`, no numpy).
- CSV/JSON export of a shadow study from the panel.
- An examples folder (Paris 121°, Sydney 5°) with a demo `.max` scene.

---

MIT licence — © /ai.oli collective.
