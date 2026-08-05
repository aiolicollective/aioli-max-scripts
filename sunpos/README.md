# sunpos

Put a **3ds Max** sun where the **real sun** was at a given place, date and
time — taking your scene's **north rotation** into account.

For architectural renders where the solar orientation has to be physically
right: shadow studies, golden hour, the sun's path across a day.

> Usage doc. For design decisions and development status, see
> [`NOTES.md`](NOTES.md).

---

## Getting started in 3ds Max

**Drag `aioli-sunpos.ms` into a 3ds Max window.** The panel opens. That is all —
nothing to install.

For a **permanent toolbar button** (once and for all):
`Customize > Customize User Interface…`, **Toolbars** tab, category **`aioli`**,
drag `aioli-sunpos` onto a toolbar. The path to this folder is baked into the
macro at drag & drop time, so a `git pull` here updates the button too. If you
move the folder, drag the `.ms` in once more.

Written for 3ds Max 2026 (Python 3.11 + `pymxs` + PySide6), with an automatic
fallback to PySide2 on earlier versions. System units are read automatically.

### Use

1. **Location** — a GPS point `48.840006, 2.276764`, or a Google Maps link
   pasted as-is (map view, pin, Street View: all fine).
2. **Date** and **local time** — wall clock time on site, not where you are.
3. **North rotation** — the angle your model is rotated by around Z.
   `0` = north towards `+Y` (3ds Max convention).
4. **Z max** — height of the gizmo above the reference point. No effect on the
   render, only on how comfortable it is to handle.
5. **Pick sun** — point at a sun already in the scene.
6. **Place sun**.

The log shows the time zone used, the azimuth, the elevation and the coordinates
**before** the scene moves. If a number looks wrong, `Ctrl+Z` undoes the lot.

### What it does, and does not do

The tool **never creates** a sun: it moves the one you point it at. It works with
**any** of them — V-Ray Sun, Corona Sun, native target light, free directional.

- Sun **with a target**: the target is the reference point and is **never
  moved**. Only the sun's position changes.
- Sun **without a target**: you type a reference point, and the tool **also
  orients** the node towards it — moving a free light would not otherwise change
  the direction of its light.

### `single` / `path` mode

`single` places the sun at the given instant. `path` **animates** the picked sun
with keyframes, sunrise to sunset (the `animationRange` is extended if needed).

On every **Place sun**, the previous position animation is **cleared** before
placing. Without that, going from `path` back to `single` would leave the keys
behind: the sun would look placed, then move again as soon as you scrubbed the
timeline.

If the sun carries animation that **did not come from this tool**, a confirmation
is asked — the tool marks the nodes it animates so it never silently destroys
somebody else's work.

### Time zone

The panel starts in **`zone`** mode on `Europe/Paris`: usable straight away, with
nothing to install, **daylight saving included**. Your settings are remembered
between sessions.

| mode | source | install |
|---|---|---|
| **`zone`** *(default)* | drop-down list, the zone's published DST rule | none |
| `manual` | raw UTC offset, for a place not in the list | none |
| `auto` | IANA database, derived from the GPS point | `setup.bat` once |

The log always states what was used, for instance
`Australia/Sydney (AEST, UTC+10, standard, offline table)`.

> **`zone` or `auto`?** The offline table is a snapshot of DST rules (34 zones,
> cross-checked against `tzdata` by the test suite). It is correct today, but a
> country changing its law makes it silently stale — and zones with unstable
> rules (Cairo, Casablanca, Jerusalem) are deliberately **absent** rather than
> approximated. `auto` mode reads the IANA database, always current. **For a date
> you are committing to with a client, use `auto`.**
>
> `auto` mode installs **nothing** into 3ds Max: the panel delegates that one
> question to the Python in this folder's `.venv` (see below). Autodesk's Python
> is never modified.

### Atmospheric refraction

On by default. Light bends in the atmosphere: the direction the sun actually lights
from is the apparent one, not the geometric one. Negligible high in the sky
(< 0.05° above 20°), but ~0.5° at the horizon — where it can halve the length of
a shadow. See *Accuracy*.

---

## Accuracy — what you can promise a client

| Source of error | Magnitude | Comment |
|---|---|---|
| NOAA algorithm | ~0.01° | negligible |
| Refraction, standard model | ~0.01° at zenith, **0.1–0.3° near the horizon** | depends on the actual weather |
| Time zone / DST | **0 or 60 min** | binary: right, or ~15° of azimuth wrong |
| GPS coordinates | < 0.001° | negligible |
| Scene north rotation | whatever you typed | **the weak link in practice** |

**Above ~10° of elevation, the sun's direction is accurate to better than
0.05°** — ten times finer than the solar disc (0.53°). On a 30 m building the
shadow is right to within a few centimetres. Contractual grade.

With these caveats:

- **Near the horizon** (< 5°, so right through golden hour), refraction depends
  on that day's temperature, pressure and inversions, which are unknowable for a
  future date. Accurate "to the standard model", not "to the weather".
- **The solar disc is 0.53° across**: real shadows have a penumbra that wide. A
  point sun gives sharper shadows than reality, however precise its position —
  turn on sun size (V-Ray Sun `size multiplier`, Corona `sun size`).
- **The time zone is a binary risk**, not a gradual one. It is by far the most
  likely and most visible error. Check the line printed in the log.
- **North rotation cannot be verified by the tool.** Wrong by 3° and none of the
  rest matters.
- **Terrain and distant obstructions are not modelled**: the tool gives the sun's
  direction, not whether it is visible from the point.

**Validity ranges.** The NOAA equations hold ~0.01° between **1800 and 2100**;
beyond that the result degrades by a few arcminutes per century and the tool says
so. The offline zone table is only valid from the year each rule took its current
form (EU 2002, US 2007, AU 2008, NZ 2007) — before that it says so and points you
at `auto`.

**A defensible way to put it**: "position computed with the NOAA algorithm,
corrected for standard atmospheric refraction, accurate to better than 0.05°
outside sunrise and sunset — provided the model's north and the time zone are
correct, both of which are verifiable on the report".

---

## 3ds Max notes

- The sun's distance has **no effect** on the render: the rays are parallel, only
  the direction counts. You can multiply X, Y, Z by the same factor. Never change
  the X:Y:Z **ratio**.
- The gizmo can **pass through geometry** with no consequence.
- At **sunrise** and **sunset**, `Z ≈ 0`: unavoidable. The tool flags it with
  `(on the horizon)`. Below the horizon, `Z` is negative — no direct sun.
- **Site altitude** plays no part: only latitude, longitude, date and time
  matter.

---

## Use outside 3ds Max *(optional)*

The calculation is available from the command line, to automate it or reuse it in
another 3D application.

### Install

```bat
setup.bat            REM Windows
./setup.sh           # macOS / Linux
```

Creates a **`.venv` inside this folder** and installs the two dependencies
(`timezonefinder`, `tzdata`). **Nothing is installed into your system Python**,
nothing is added to `PATH`. To uninstall: delete `.venv`. Requires Python ≥ 3.9.
The test suite runs at the end.

This same install is what enables the `auto` time zone mode in the 3ds Max panel.

### Command line

```bat
run.bat "48.840006, 2.276764" "2026-09-29 19:30" --north 121 --zone Europe/Paris
```

```
  sunpos
  ------------------------------------------------------
  Location   : 48.840006, 2.276764
  Time zone  : Europe/Paris (CEST, UTC+2, DST, offline table)
  Local time : 2026-09-29 19:30
  Sun        : azimuth 266.18 deg   elevation 0.36 deg
               (geometric -0.14 deg + 0.502 deg refraction)
  Day        : sunrise 07:47   noon 13:41   sunset 19:34   (11.78 h)
  North rot. : 121 deg      distance 2401.4 cm
  ------------------------------------------------------
  X =        1371.1 cm
  Y =       -1971.4 cm
  Z =          15.3 cm
```

Sun path, one point every 2 h, and machine-readable export:

```bat
run.bat "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2
run.bat "48.84, 2.27" 2026-06-21 --path 1 --json > day.json
```

| Option | Role | Default |
|---|---|---|
| `--north DEG` | Z rotation of the scene's north axis | `0` |
| `--target X,Y,Z` | reference point / sun target (cm) | `0,0,0` |
| `--zmax CM` | max Z height above the reference | `1500` |
| `--distance CM` | force a fixed distance, ignore `--zmax` | — |
| `--path STEP_H` | sun path, one point every `STEP_H` hours | — |
| `--zone IANA` | zone from the offline table — nothing to install | — |
| `--tz IANA` | zone through `tzdata` | — |
| `--utc-offset H` | forced UTC offset | — |
| `--no-refraction` | purely geometric elevations | corrected |
| `--list-zones` | list the zones available to `--zone`, then exit | — |
| `--json` | JSON output instead of the table | — |

Time zone priority: `--utc-offset` > `--zone` > `--tz` > auto (GPS). Options can
go **anywhere** on the line, and negative latitudes need no escaping.

### As a library

```python
from datetime import datetime
from sunpos_core import compute_sun, sun_path
from sunpos_zones import zone_offset

tz, *_ = zone_offset("Europe/Paris", datetime(2026, 9, 29, 19, 30))

res = compute_sun(
    "48.840006, 2.276764",
    datetime(2026, 9, 29, 19, 30),      # local wall clock time, NAIVE datetime
    tz,
    north_rotation_deg=121,
    z_max_cm=1500,
)
print(res.X_cm, res.Y_cm, res.Z_cm, res.horizon)
```

`sunpos_core` and `sunpos_zones` use **the standard library only**.
`res.geometric_elevation_deg` and `res.refraction_deg` break the elevation down;
`compute_sun(..., refraction=False)` goes back to pure geometry.

---

## Tests

```bash
.venv/bin/python -m pytest tests -q      # or: python tests/test_sunpos.py
```

47 tests: GPS and Maps link parsing, julian day against Meeus' references,
extremes of the equation of time, declinations at solstices and equinoxes,
year-on-year drift, refraction, the zone table cross-checked against `tzdata` on
24 dates per zone, positions in both hemispheres, sunrise/sunset against observed
tables, the north rotation convention, polar day and night, ambiguous local
times, and **parity between the CLI and the Max tool**.

The maths and the CLI are covered. The `pymxs` layer is not — see
[`NOTES.md`](NOTES.md) for what remains to be checked inside Max.

---

MIT licence — © /ai.oli collective.
