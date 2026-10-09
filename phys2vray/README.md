# phys2vray

> **In test.** Written without a 3ds Max at hand, now being tried on real
> Blender imports and corrected as we go. Run **REPORT** first, read the
> Listener (`F11`) after every run, and expect changes on `git pull`. What is
> still unverified is listed in [`NOTES.md`](NOTES.md).

Replace the native **Physical Materials** on the selected objects with
**VRayMtl**, every texture map plugged back into the right V-Ray slot as a
**VRayBitmap**; the VRayBitmaps of a material share one **VRayUVWRandomizer**,
each material has its own. Made for FBX files exported from Blender, works on
any Physical Material.

And the other way round, since 1.4: the **VRayMtl** of the selection become
**Physical Materials** for an **FBX** and / or **glTF** export that opens in
Blender with its textures — without touching the scene, or in the scene if you
want to export it yourself. See [V-Ray → Physical](#v-ray--physical-exports-to-blender).

- **File:** `aioli-phys2vray.ms` — single file, no dependency
- **Compatibility:** 3ds Max 2017+ (Physical Material), V-Ray 5+ (metalness,
  roughness mode, coat, sheen). Written for 3ds Max 2026 / V-Ray 7.
- **Version:** 1.4 — **in test**, see [`NOTES.md`](NOTES.md) and the [changelog](#changelog)

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
survives a restart of Max. **The button reads the file again at every click**, so
a `git pull` applies at the next click, without restarting Max. Move the clone
and you just drag the `.ms` in once more — see the
[root README](../README.md#toolbar-buttons).

Settings are remembered between sessions in an `.ini` in `getDir #plugcfg`.

---

## Use

1. Select the imported objects. The panel counts the Physical Materials found on
   them, including inside Multi/Sub-Object materials.
2. **REPORT** — prints to the MAXScript Listener (`F11`) what each Physical holds
   (values, maps, bitmap files) and what CONVERT would do with it. Changes nothing.
3. **CONVERT TO V-RAY** — builds the VRayMtl, swaps it in, in a single undo. Every
   step is logged in the Listener, with a `!` in front of anything that needs a look.

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
| Normal Bump in the bump slot | VRayNormalMap (option, default), green flipped for OpenGL maps (option, default) |
| Bitmap, in any slot | VRayBitmap (option, default) + one VRayUVWRandomizer per material (option, default) |
| Displacement map + amount | Displacement map, amount × 100 |

Maps other than bitmaps (Output, Color Correction, procedurals…) are **reused,
not copied**: the VRayMtl points at the same nodes. Two kinds are rebuilt, for
each material on its own:

- **Bitmaps become VRayBitmaps** — same file, UVW coordinates (tiling, offset,
  angle, channel, blur), output settings, mono / RGB output and alpha source.
  Data maps (roughness, metalness, normal, bump, opacity…) get the transfer
  function *none* and the RGB primaries *Raw* (no conversion at all, as Chaos
  recommends); colour maps get *from 3ds Max*, so 3ds Max's colour management
  decides per file as it did for the Bitmap, primaries left on *Default*. The
  VRayBitmaps of a material share that material's VRayUVWRandomizer
  (`mapSource`); two materials never share one. A Bitmap used by two materials
  gives one VRayBitmap in each.
- **Normal Bumps become VRayNormalMaps**, with the same maps, multipliers and
  flips.

The old Bitmaps and Normal Bumps are **never modified**: another material may
still use them. Once nothing in use needs them, their nodes are taken out of
the Slate views, so no cut-off node is left next to the new material. A Bitmap
inside a map reused as it is (Output, Mix, a Normal Bump that is kept) stays a
Bitmap, and the log says so.

Not converted, and reported as such: sub-surface scattering, thin film,
anisotropy, base weight map, emission colour temperature. Any other map left in
a Physical slot is listed by name in the Listener — nothing is dropped silently.

---

## Options

| Control | Effect |
|---|---|
| Bitmap → VRayBitmap | Every Bitmap plugged in a converted material becomes a VRayBitmap in that material. The Bitmap itself is not modified. |
| VRayUVWRandomizer per material | Each material gets its own VRayUVWRandomizer, named after it (`<material> UVW randomizer`) and shared by all its VRayBitmaps. **Check its settings**: random offset, rotation or scale misplace unwrapped (non-tiling) textures. |
| White reflection, Fresnel from IOR (PBR) | Reflection white, Fresnel driven by the IOR: what a Principled BSDF means. Off, the reflection is the Physical reflectivity × reflection colour and their maps are plugged. |
| Roughness map is | *As set in the Physical* follows the Inv toggle. *Roughness* / *Glossiness* force how the map is read, when the import got it wrong; the scalar value is converted to match. |
| Normal Bump → VRayNormalMap | Rebuilds Normal Bumps as VRayNormalMap. Off, the Normal Bump is plugged as it is (V-Ray renders it too). |
| Bump bitmap named \*normal\* → normal map | A bare bitmap in the bump slot whose file name says normal (`normal`, `nrm`, `_nor`, `_n`) is wrapped in a VRayNormalMap instead of being read as a height map. Its bump amount is set to 100. |
| Flip green: OpenGL normal maps (Blender) | **On by default.** V-Ray for 3ds Max reads normal maps as DirectX (Y-), Blender writes OpenGL (Y+) — confirmed by Chaos. A flip already set on a Normal Bump is kept. Untick for DirectX maps (made for 3ds Max, Unreal, Substance's DirectX preset). |
| Transparency map → Opacity | Reads a map in the transparency slot as an alpha cutout (Blender exports its alpha there) and sends it to opacity instead of refraction. |
| Data maps in linear | Roughness, metalness, normal, bump, opacity are data, not colour. As VRayBitmap: transfer function *none*, RGB primaries *Raw*. A data map that stays a Bitmap (option off, or inside a reused map) is reloaded with gamma 1.0 (gamma mode) or the `Raw` colour space (OCIO, 3ds Max 2024+), unless something outside the run uses it. A bitmap also used in a colour slot is treated as colour. |

---

## Behaviour and edge cases

- **The Physical is only read.** The VRayMtl is built next to it, then
  `replaceInstances` swaps every reference: objects, Multi/Sub-Object slots,
  Material Editor slots. Material name and effects channel are kept.
- **Shared materials stay shared.** A Physical used by ten objects becomes one
  VRayMtl used by the same ten objects. Maps rebuilt (VRayBitmap,
  VRayNormalMap) belong to one material each.
- **One undo** for the whole conversion, Auto Key forced off during it.
- **V-Ray not loaded**: the tool says so and does nothing.
- **Older V-Ray** (no metalness, roughness mode, coat or sheen): what cannot be
  set is reported, the rest is converted.

---

## V-Ray → Physical (exports to Blender)

FBX and glTF exporters know the Physical Material, Bitmaps and Normal Bumps, not
V-Ray's classes: a VRayMtl reaches Blender without its textures. The lower part
of the panel converts the other way.

- **EXPORT SELECTION…** — asks for a file name, gives the selected objects
  Physical Materials **for the export only**, writes the `.fbx` and / or `.glb`
  (same name, same folder), then gives every object its own material back. The
  scene is left as it was: nothing to undo, nothing to save.
- **CONVERT IN SCENE** — replaces the VRayMtl of the selection with Physical
  Materials in the scene, wherever they are used (it asks first if objects
  outside the selection share them), in a single undo. Export yourself, Ctrl+Z
  to go back.

| VRayMtl | Physical |
|---|---|
| Diffuse + map (amount on a black swatch → base weight) | Base colour + map |
| Diffuse roughness + map | Diffuse roughness + map |
| Reflection colour / map | Reflectivity × reflection colour / map (white with a map) |
| Reflection glossiness + map, *Use roughness* | Roughness + map: a value alone is turned into a roughness; a glossiness **map** gets *Inv* on |
| Metalness + map | Metalness + map |
| IOR (lock on: refraction IOR, off: reflection IOR) + map | IOR + map |
| Refraction colour / map, fog colour and depth | Transparency, transparency colour / map, depth |
| Refraction glossiness + map | Transparency roughness (locked when it matches the reflection) |
| Opacity map | Cutout map |
| Self-illumination, multiplier, map | Emission, luminance = multiplier × 477.464, map |
| Coat, sheen + maps | Coating, sheen + maps |
| Bump map + amount, VRayNormalMap | Bump map, amount ÷ 100, Normal Bump (flips and space kept) |
| Displacement map + amount | Displacement map, amount ÷ 100 |
| VRayBitmap | Bitmap: same file, UVW coordinates, output; data maps read linear |

- **Bitmaps** already in the VRayMtl are reused as they are. **VRayBitmaps**
  become Bitmaps; their UVW randomizer is not carried over (FBX, glTF and
  Blender do not know it).
- **Other maps** (Output, Color Correction, Triplanar…) are not carried by FBX
  or glTF. With *Plug the texture found inside other maps* (default), a map
  holding a single texture is replaced by that texture, and the log says what
  is lost; otherwise it is plugged as it is and Blender will not see it.
- **Multi/Sub-Object** materials are kept, their VRayMtl converted. Another
  container (VRay2SidedMtl, VRayBlendMtl, VRayMtlWrapper…) is exported as its
  first sub-material.
- **Normal maps:** a V-Ray normal map read with the green flipped is an OpenGL
  file, what Blender reads. One read without the flip is a DirectX file: the log
  warns that its green will be inverted in Blender.
- **Refraction:** Blender reads an FBX transparency as alpha (see-through), not
  as glass. The log warns on every transparent material.
- **Not converted, and reported:** anisotropy, translucency, map amounts below
  100 % (the map is plugged at 100 %), and any other map left in a VRayMtl slot.

| Control | Effect |
|---|---|
| FBX / glTF binary (.glb) | Which files EXPORT writes. glTF needs 3ds Max 2023+; Blender rebuilds a full Principled BSDF from it (roughness, metalness, normal, alpha), more faithfully than from an FBX. |
| Embed textures in the FBX | Embed Media: the `.fbx` carries its textures and Blender unpacks them. The FBX exporter's own setting is put back afterwards. The other FBX settings are the exporter's current ones. |
| Plug the texture found inside other maps | See above. |

---

## Changelog

- **1.4** — The other way round: VRayMtl → Physical Material, for an FBX and / or
  glTF export that Blender opens with its textures. EXPORT SELECTION… does it
  for the export only and leaves the scene as it was; CONVERT IN SCENE does it
  in the scene, in one undo. VRayBitmap → Bitmap, VRayNormalMap → Normal Bump,
  wrapper maps replaced by their single texture (option). The forward CONVERT
  button is now *CONVERT TO V-RAY*.
- **1.3** — One VRayUVWRandomizer **per material**, shared by that material's
  VRayBitmaps (1.1 and 1.2 had one for the whole scene). VRayBitmaps and
  VRayNormalMaps are now built per material and plugged straight into the new
  VRayMtl: the old maps are never swapped in place any more, which is what left
  every map twice in the Slate view. The old maps' nodes are then removed from
  the Slate views when nothing in use needs them. Data VRayBitmaps get the RGB
  primaries *Raw*. A data map that stays a Bitmap is still made linear.
- **1.2** — The toolbar button reads the file again at every click: until now
  it reopened the version already in memory, so a `git pull` only applied after
  restarting 3ds Max (most likely why the first 1.1 test showed no VRayBitmap).
  The old Normal Bump is swapped for its VRayNormalMap everywhere instead of
  being left orphaned in the Slate view.
- **1.1** — Bitmaps become VRayBitmaps (data maps linear, colour maps *from 3ds
  Max*), all sharing one VRayUVWRandomizer, reused by name between runs. *Flip
  green* on by default: V-Ray for 3ds Max reads normals as DirectX, Blender
  writes OpenGL. A flip already set on a Normal Bump is now kept (it used to be
  toggled). Bitmaps used by a modifier or object outside the run are left alone.
  Settings key renamed (`FlipGreenOpenGL`) so an old saved *off* does not
  override the new default.
- **1.0** — First version, in test.

---

## Credit

The emission ratio (luminance in cd/m² ÷ 477.464) is the one used by Emanuele
Lecchi's V-Ray → Physical converter
([Lele's V-Ray MaxScript Tools](https://github.com/EmanueleLecchi/Lele-s-V-Ray-MaxScript-Tools)),
read in reverse.

MIT licence — © /ai.oli collective.
