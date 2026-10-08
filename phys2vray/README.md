# phys2vray

> **In test.** Written without a 3ds Max at hand, now being tried on real
> Blender imports and corrected as we go. Run **REPORT** first, read the
> Listener (`F11`) after every run, and expect changes on `git pull`. What is
> still unverified is listed in [`NOTES.md`](NOTES.md).

Replace the native **Physical Materials** on the selected objects with
**VRayMtl**, every texture map plugged back into the right V-Ray slot.
Made for FBX files exported from Blender, works on any Physical Material.

- **File:** `aioli-phys2vray.ms` — single file, no dependency
- **Compatibility:** 3ds Max 2017+ (Physical Material), V-Ray 5+ (metalness,
  roughness mode, coat, sheen). Written for 3ds Max 2026 / V-Ray 7.
- **Version:** 1.0 — **in test**, see [`NOTES.md`](NOTES.md)

---

## The problem

A Blender asset exported to FBX comes into 3ds Max with Physical Materials:
Blender's Principled BSDF goes through FBX and the importer rebuilds it as a
Physical. To render with V-Ray, each one has to be replaced by hand with a
VRayMtl and every map re-plugged — base colour, roughness, metalness, normal,
opacity — on every material of every asset.

This does it on the selection in one click.

---

## Install and run

Drag `aioli-phys2vray.ms` into a 3ds Max window, or `Scripting > Run Script…`.
The panel opens and a macro is registered under the **`aiolicollective`** category
(action `phys2vray`) for a toolbar button or a keyboard shortcut.

The path to this file is baked into the macro when you drag it in, so the button
survives a restart of Max and follows `git pull`. Move the clone and you just drag
the `.ms` in once more — see the [root README](../README.md#toolbar-buttons).

Settings are remembered between sessions in an `.ini` in `getDir #plugcfg`.

---

## Use

1. Select the imported objects. The panel counts the Physical Materials found on
   them, including inside Multi/Sub-Object materials.
2. **REPORT** — prints to the MAXScript Listener (`F11`) what each Physical holds
   (values, maps, bitmap files) and what CONVERT would do with it. Changes nothing.
3. **CONVERT** — builds the VRayMtl, swaps it in, in a single undo. Every step is
   logged in the Listener, with a `!` in front of anything that needs a look.

A material is replaced **wherever it is used**, the way the material editor
would do it. If objects outside the selection share one of the materials, the
tool asks before going on.

---

## Mapping

| Physical | VRayMtl |
|---|---|
| Base colour × base weight, base colour map | Diffuse, diffuse map (weight → map amount) |
| Diffuse roughness + map | Diffuse roughness + `texmap_roughness` |
| Reflectivity × reflection colour + maps | Reflection: white (PBR option, default) or reflectivity × colour |
| IOR + map | Refraction IOR, Fresnel on, IOR locked |
| Roughness + map, Inv toggle | Reflection glossiness + map, *Use roughness* following the Inv toggle |
| Metalness + map | Metalness + map |
| Cutout map | Opacity map |
| Transparency map | Opacity (alpha option, default) or refraction |
| Transparency × transparency colour + maps | Refraction colour + map; depth → fog colour and depth |
| Transparency roughness (locked or not) | Refraction glossiness + map |
| Thin-walled | Thin-walled, when the VRayMtl has it |
| Emission × colour × luminance + maps | Self-illumination colour, map, multiplier = weight × luminance / 477.464 |
| Coating, colour, roughness, IOR, bump + maps | Coat layer |
| Sheen, colour, roughness + maps | Sheen layer |
| Bump map + amount | Bump map, amount × 100 |
| Normal Bump in the bump slot | VRayNormalMap (option, default) |
| Displacement map + amount | Displacement map, amount × 100 |

The maps themselves are **reused, never copied**: the VRayMtl points at the same
Bitmap nodes, with their tiling, crop and output settings. Normal Bumps are the
exception — rebuilt as VRayNormalMap with the same maps, multipliers and flips.

Not converted, and reported as such: sub-surface scattering, thin film,
anisotropy, base weight map, emission colour temperature. Any other map left in
a Physical slot is listed by name in the Listener — nothing is dropped silently.

---

## Options

| Control | Effect |
|---|---|
| White reflection, Fresnel from IOR (PBR) | Reflection white, Fresnel driven by the IOR: what a Principled BSDF means. Off, the reflection is the Physical reflectivity × reflection colour and their maps are plugged. |
| Roughness map is | *As set in the Physical* follows the Inv toggle. *Roughness* / *Glossiness* force how the map is read, when the import got it wrong; the scalar value is converted to match. |
| Normal Bump → VRayNormalMap | Rebuilds Normal Bumps as VRayNormalMap. Off, the Normal Bump is plugged as it is (V-Ray renders it too). |
| Bump bitmap named \*normal\* → normal map | A bare bitmap in the bump slot whose file name says normal (`normal`, `nrm`, `_nor`, `_n`) is wrapped in a VRayNormalMap instead of being read as a height map. Its bump amount is set to 100. |
| Flip green on normal maps | For DirectX normal maps. Blender writes OpenGL ones: leave off unless the relief looks inverted. |
| Transparency map → Opacity | Reads a map in the transparency slot as an alpha cutout (Blender exports its alpha there) and sends it to opacity instead of refraction. |
| Data maps in linear | Roughness, metalness, normal, bump, opacity bitmaps are data, not colour: they are reloaded with gamma 1.0 (gamma mode) or the `Raw` colour space (OCIO, 3ds Max 2024+). A bitmap also used in a colour slot, or by a material outside the run, is left as it is. |

---

## Behaviour and edge cases

- **The Physical is only read.** The VRayMtl is built next to it, then
  `replaceInstances` swaps every reference: objects, Multi/Sub-Object slots,
  Material Editor slots. Material name and effects channel are kept.
- **Shared materials stay shared.** A Physical used by ten objects becomes one
  VRayMtl used by the same ten objects. A Normal Bump met in several materials
  becomes one VRayNormalMap.
- **One undo** for the whole conversion, Auto Key forced off during it.
- **V-Ray not loaded**: the tool says so and does nothing.
- **Older V-Ray** (no metalness, roughness mode, coat or sheen): what cannot be
  set is reported, the rest is converted.

---

## Credit

The emission ratio (luminance in cd/m² ÷ 477.464) is the one used by Emanuele
Lecchi's V-Ray → Physical converter
([Lele's V-Ray MaxScript Tools](https://github.com/EmanueleLecchi/Lele-s-V-Ray-MaxScript-Tools)),
read in reverse.

MIT licence — © /ai.oli collective.
