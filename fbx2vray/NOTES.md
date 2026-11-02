# fbx2vray — technical notes

Design decisions, traps already hit, and what is still unverified. Read before
changing something that looks odd: it may be a fix.

## Status: in test

- **Tried in 3ds Max 2026 / V-Ray 7** (as our library's script, before this repo):
  VRayMtl, VRayBitmap, Color Correction, Output, VRayNormalMap on two artworks
  and a spotlight; a full import of an animated artwork (11 materials, 11 lights:
  VRayLight spheres and VRayIES, dimensions right). Noise in XYZ object
  coordinates confirmed by eye.
- **Not tried in 3ds Max yet:** everything new in 1.0 — the panel, the macro,
  the Python call from MAXScript, APPLY .JSON TO SELECTION, the Ask / Reuse /
  Rebuild window, `replaceInstances` on a rebuild, the single undo; and the
  material families none of the tried assets carried (see question 1).
- **Tested outside Max** against a fake `pymxs` that records every object created
  and every property set:
  - the 1.0 rebuild code, reading format 2, against the library's script reading
    format 1, on 64 real files (61 library assets, 3 exports of a project):
    275 materials, 103 lights, 22 light placements — **identical** sequences of
    objects and properties, warnings included (node names apart: the suffixes
    are now in English);
  - scenarios: fresh import (one VRayMtl per name, shared by the objects, inside
    one undo), a second FBX sharing two material names (reuse: the same material;
    one material per name in the scene), rebuild (new material, swapped with
    `replaceInstances`), cancel (nothing imported), apply on a selection
    (children included, objects outside untouched, unrelated materials listed),
    apply with nothing selected (question, yes / no), no `_vray.json` (phys2vray
    opened from the clone), format 1 read = format 2 written and read again, no
    format 1 key left after the upgrade (keys checked, not text), lights placed
    in their parents, a second copy of an asset getting its own lights, reuse
    merging duplicates, a broken graph skipped while the others are built, an
    unreadable `_vray.json` (question before importing the FBX alone).
  - reviewed by a separate agent before the first push; its findings are fixed
    (Yes / No / Cancel answers read as `#yes`, label widths, the points above).

## Open questions (to settle in Max)

| # | Question | Where |
|---|---|---|
| 1 | Property names only checked on the families the tried assets carry. Untried: glass with falloff, `VRayDirt`, `VRayTriplanarTex`, `Composite`, `Tiles` (names guessed among several, `_set_first`), `VRayMultiSubTex.texmap`, `VRayBlendMtl.coatMtl[i]`, `VRay2SidedMtl` options, `VRayIES` shape. A wrong name prints a `!` line; collect them on the first asset that has them. | `Builder`, `make_light` |
| 2 | Does `python.ExecuteFile` run the file as `__main__` in 3ds Max 2026? The file also runs `main()` when the panel's request global is set, so the panel works either way; Run Script relies on `__main__`. | end of `fbx2vray.py` |
| 3 | The modal window (`createDialog … modal:true`) opened from Python, itself called from a rollout button: does it block and return the answer? Fallback if the call throws: a Yes / No / Cancel box. | `ask_existing`, `aioli_fbx2vray_ask` |
| 4 | `ColorPipelineMgr.renderingColorSpace`: right property name? If not, the Listener just says the space was not read. | `check_rendering_space` |
| 5 | `rt.replaceInstances(oldMtl, newMtl)` on a rebuild: does it reach Multi/Sub slots of objects outside the selection, and the Material Editor slots, as with phys2vray's maps? | `apply_materials` |
| 6 | Names: does the FBX importer ever change a material name (characters, a second import of the same name)? Matching is exact; the Listener lists file materials not found on the objects. | `apply_materials` |
| 7 | `m.materialList[i] = x` from Python writes through to the Multi/Sub (it did in the library script, on one asset). | `apply_materials` |
| 8 | A 300 MB FBX (25 scans with 8K textures): import time, and the selection of every imported node at the end. | `run_import` |

## Design decisions (do not undo without a reason)

### A tool of its own, next to phys2vray
phys2vray converts **any** Physical by correspondence (and does the way back to
Blender); fbx2vray rebuilds **exactly** what a `_vray.json` describes. Different
inputs, different languages (phys2vray is single-file MAXScript, this is Python
because it parses JSON graphs), tested and versioned separately. They meet in one
place: no `_vray.json` → phys2vray opens.

### The panel is MAXScript, the work is Python
The `.ms` is the launcher (same macro mechanism as the other tools) and a native
rollout; each button sets the global `aioli_fbx2vray_request` (`key=value` lines:
action, existing, lights, folder) and runs `fbx2vray.py` with
`python.ExecuteFile`. Both files are read again at every click, so a `git pull`
applies without restarting Max. No PySide: nothing to keep in sync with Max's Qt.

### The question comes before the import
Which V-Ray materials of the file are already in the scene does not depend on
the import (it only brings Physical Materials), so the question is asked first:
Cancel then means nothing imported, not an FBX left half done.

### Reuse or rebuild, never a second material of the same name
Before 1.0, a second FBX sharing a material name gave a second VRayMtl with that
name. Our files follow "one name = one setting", so the scene keeps one material
per name: **reuse** puts the existing one on the new objects; **rebuild** makes it
again from the file and swaps it everywhere with `replaceInstances` (a new export
version must reach every object that uses it). **Ask** is the default because
rebuild throws away tweaks made in Max.

### Every imported object, not the first root
The library script took the first top-level node of the import (an asset has one
`…_ROOT`) and only converted under it. An FBX with several top-level nodes kept
the rest in Physical. 1.0 converts every node the import created; the root is
still used to place lights that have no parent.

### Already V-Ray = left alone
A slot already holding a V-Ray material (`VRayMtl`, `VRayLightMtl`,
`VRayBlendMtl`, `VRay2SidedMtl`) is never converted again by a slot-by-slot pass;
only **rebuild** replaces it, deliberately. Running APPLY a second time finds the
file's V-Ray materials already there: Ask opens the window, Reuse changes
nothing, Rebuild makes them again.

### What counts as "already in the scene"
The materials on the objects, top level and Multi/Sub slots, of the four V-Ray
classes above. A material only in the Slate, nested in a Blend / 2-Sided, or of
another V-Ray class (wrapper, override) is not seen: the file's material is then
built as new, and the scene has two of that name. **Reuse** also merges
duplicates of the same name (left by imports before 1.0) into the first one.

### One failure does not stop the run
Each material is built, and each light created, in its own `try`: a broken graph
or a missing key gives a `!` line and leaves that material as it was; the others
go on, inside the same undo. A `_vray.json` that cannot be read stops IMPORT
before the FBX, with a question: import the FBX alone?

### Lights: already there = same name under the same parent
Before 1.0 a light was skipped when any node of that name existed in the scene,
so a second copy of an asset came without lights. Now it is skipped only when
its parent (or, without a parent, the top level) already holds that name.

### Handles, not lists
Deduplication of nodes, materials and maps goes through `getHandleByAnim` sets:
`x in list` on pymxs wrappers crosses into MAXScript at every comparison, and
APPLY on a whole scene can meet thousands of nodes.

### Single undo, the import outside it
Materials and lights are created in `pymxs.undo(True, "aioli-fbx2vray")`. The FBX
importer is not undoable in 3ds Max; it runs before the undo block. The old
materials are taken out of the Slate views inside the same block: after Ctrl+Z
they are back on the objects but probably not in the Slate views (as with
phys2vray) — open them again from the objects if needed.

### Colour spaces of bitmaps: the writer decides
`image.color_space` is how **V-Ray** decoded the image in the source scene, not
Blender's setting: an 8-bit roughness read by V-Ray's *auto* mode was rendered as
sRGB, so it is set as sRGB here (fidelity to the validated render, decided by
victor.oli, 2026-10-27). Colour = transfer sRGB + primaries sRGB, data = none +
Raw, the phys2vray 1.6 rule for ACEScg scenes.

### Format 2 in English, format 1 still read
The repo is in English, so is the format. Files already written stay valid:
`upgrade_v1` renames the keys on load, values untouched, and nothing is
rewritten on disk. The code reads format 2 only. The equivalence test above is
what guarantees the upgrade lost nothing.

### Kept from the library script (hit in test, 2026-10-27)
- **Units:** the FBX importer's automatic setting; `ConvertUnit` expects a unit
  as text, not a boolean, and broke the scale when forced.
- **3D maps in XYZ object coordinates**, including V-Ray's world mapping: the
  pattern follows the object when it is moved.
- **Old materials leave the Slate views** when nothing in the scene uses them
  any more (phys2vray's method); a material nothing uses is not saved with the
  scene.
- **Fog:** V-Ray for Blender converts the fog multiplier with the units itself;
  the value is set as it is and flagged for a check in a render.

## Ideas, not done

- Socket multipliers other than 100 % (`multiplier` on a link): one in 64 files.
- A REPORT button (what would be built, without touching the scene), as in phys2vray.
- Rebuild lights too on **rebuild** (today a light already under its parent is skipped).
