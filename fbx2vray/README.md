# fbx2vray

> **In test.** The material and light rebuild has been used since October 2026
> on our asset library and tried in 3ds Max on a library asset; the panel, the
> work on an FBX already in the scene and the question about existing V-Ray
> materials are new in 1.0 and not yet tried in Max. Read the Listener (`F11`)
> after every run. What is still unverified is listed in [`NOTES.md`](NOTES.md).

Import an FBX into 3ds Max with its **exact V-Ray materials and lights**, rebuilt
from the `<name>_vray.json` written next to it — on import, or on an FBX that is
already in the scene.

An FBX exported from Blender carries the geometry and a simplified material
(Principled BSDF → Physical Material). When the scene was set up in **V-Ray for
Blender**, the real materials are V-Ray node graphs the FBX cannot carry. Our
Blender-side exporter writes them, with the V-Ray lights, into a `_vray.json`
next to the FBX; fbx2vray reads it and rebuilds each material in 3ds Max with the
matching V-Ray classes, finding the materials by their name.

- **Files:** `aioli-fbx2vray.ms` (panel and launcher) + `fbx2vray.py` (the work) —
  Python on what 3ds Max ships (`pymxs`, standard library), nothing to install
- **File format:** [`FORMAT.md`](FORMAT.md) — format 2 (English keys); format 1
  (French keys, our earlier files) is read too
- **Compatibility:** 3ds Max 2022+ (Python 3), V-Ray 5+. Written for 3ds Max 2026 / V-Ray 7.
- **Version:** 1.0 — **in test**, see the [changelog](#changelog)

---

## fbx2vray or phys2vray?

| | fbx2vray | [phys2vray](../phys2vray/) |
|---|---|---|
| Needs | the FBX's `_vray.json` | nothing: any Physical Material |
| Gives | the V-Ray materials of the source scene, node for node (falloffs, dirt, blends, light materials, triplanar…) and its V-Ray lights | a VRayMtl per Physical, by correspondence of the PBR slots |
| Use it for | FBX from our V-Ray for Blender scenes and library | any other FBX; and the way back (V-Ray → Blender) |

They work together: IMPORT FBX without a `_vray.json` imports the FBX, selects
what came in and opens phys2vray, one click away from CONVERT TO V-RAY.

---

## Install and run

Drag `aioli-fbx2vray.ms` into a 3ds Max window, or `Scripting > Run Script…`.
The panel opens and a macro is registered under the **`aiolicollective`** category
(action `fbx2vray`) for a toolbar button or a keyboard shortcut. Keep the `.ms`
next to `fbx2vray.py`.

The path is baked into the macro when you drag it in, so the button survives a
restart of Max, and **both files are read again at every click**: a `git pull`
applies at the next click. Move the clone and you drag the `.ms` in once more —
see the [root README](../README.md#toolbar-buttons).

Options are remembered between sessions in an `.ini` in `getDir #plugcfg`, with
the last folder used.

---

## Use

**IMPORT FBX…** — pick an FBX.
- With `<name>_vray.json` next to it: the FBX is imported (no dialog: smoothing
  groups, animation, no cameras or lights from the FBX, units automatic), then
  every material named in the file is replaced by its V-Ray rebuild on **all the
  imported objects**, and the file's lights are created.
- Without: the FBX is imported alone with its Physical Materials, the new objects
  are selected and phys2vray opens.

**APPLY .JSON TO SELECTION…** — for an FBX imported earlier (File > Import, or
before the `_vray.json` existed). Pick a `_vray.json`: its materials replace the
materials of the same name on the selection **and its children**. Nothing
selected: it asks before taking the whole scene. Materials that are not in the
file are left as they are and listed (phys2vray handles those).

**A V-Ray material with the same name is already in the scene** (a second FBX
sharing materials with the first, a new version of an export, a second run):

| Option | |
|---|---|
| **Ask** (default) | a window lists them before anything happens: **Reuse**, **Rebuild from .json**, or **Cancel** (with IMPORT, nothing is imported) |
| **Reuse it** | the existing V-Ray material goes on the new objects, untouched (your tweaks stay) |
| **Rebuild it from the .json** | made again from the file and swapped **everywhere it is used** in the scene — for a new version of the export |

Either way the file's materials end up as one material per name on the
objects: with **Reuse**, duplicates of the same name left by earlier imports are
merged into the first one. The check looks at the materials on the objects
(Multi/Sub slots included), not at materials only sitting in the Slate or nested
in a Blend. A slot already in V-Ray is never converted again by accident.

Materials and lights are created in a **single undo**. The FBX import itself
cannot be undone in 3ds Max (delete the objects).

**Create the lights of the .json** (on by default): `VRayLight` (sphere,
rectangle, disc) and `VRayIES`, placed in their parent object (same name in the
scene) or relative to the export's root, animated ones keyed frame by frame,
lights hidden in Blender created off and hidden. A light whose name is already
under the same parent is not created again; a second copy of an asset gets its
own lights.

The Listener lists what was built, reused, rebuilt, what the file has that the
objects do not, and every `!` — a property 3ds Max refused, something not
carried over, a material or light that could not be built (left as it was).
The rest of the run goes on. A `_vray.json` that cannot be read: IMPORT asks
before importing the FBX alone.

---

## What is rebuilt

| V-Ray for Blender | 3ds Max |
|---|---|
| `BRDFVRayMtl` | `VRayMtl` (diffuse, reflection, glossiness or roughness, Fresnel IOR, metalness, refraction, fog, opacity, self-illumination, coat, sheen, translucency, bump / normal) |
| `BRDFLight` | `VRayLightMtl` |
| `BRDFLayered` | `VRayBlendMtl` |
| `Mtl2Sided` | `VRay2SidedMtl` |
| `MetaImageTexture` | `VRayBitmap` — colour: transfer sRGB + primaries sRGB; data: none + Raw (the same rule as phys2vray 1.6) |
| `TexNormalBump` (normal map) | `VRayNormalMap`, flips as in the source |
| `TexFalloff` | `Falloff`, mix curve from the `TexRemap` that drives it |
| `TexDirt` | `VRayDirt` |
| `TexNoiseMax`, `TexCellular`, `TexTiles`, `TexMix` | `Noise`, `Cellular`, `Tiles`, `Mix` |
| `TexTriPlanar` | `VRayTriplanarTex` |
| `TexMulti` | `VRayMultiSubTex` |
| `TexLayeredMax` | `Composite` |
| `ColorCorrection` | `Color Correction` |
| `TexOutput`, `TexCombineColor` / `Float`, linear `TexRemap` | `Output` (and `Mix`) |
| `UVWGenChannel` | tiling and map channel of the map |
| object / world coordinates | XYZ object (3D maps), planar from object (bitmaps) |

Sizes given in metres (dirt radius, noise size, triplanar size, light sizes) are
converted to the scene units. Not carried over, and said in the Listener:
`UVWGenRandomizer`, UV offsets, non-linear `TexRemap` curves, channel rewiring
in a colour correction. Not carried over and not said: socket multipliers other
than 100 % (one socket in our 64 files).

**Colours** are set as the linear values of the source scene's rendering space
(ACEScg in ours, see `rendering_space` in [`FORMAT.md`](FORMAT.md)): right in a
scene that renders in the same space.

---

## Changelog

- **1.0** (2026-11-02) — in test. The library's import script, put into this
  repo: panel and macro, APPLY .JSON TO SELECTION for an FBX already in the scene,
  materials replaced on every imported object (not only under the first root),
  existing V-Ray materials of the same name reused or rebuilt (with a question by
  default), a single undo, format 2 in English with format 1 still read; a
  material or light that fails is skipped, the rest goes on; lights skipped only
  when already under the same parent.
