# phys2vray — technical notes

> Handover note. Read this before picking the development back up. The
> [`README.md`](README.md) next to it is the usage doc; this file records the
> design decisions and what is still unverified. Please do not undo a decision
> without reading why it is there.

---

## Status: in test — written blind, being corrected on real imports

v1.0 was written without a 3ds Max at hand. Property names were taken from
Autodesk's MAXScript docs and from scripts known to work (Chaos developer
Emanuele Lecchi's V2A and normalBumpConverter, James Vella's converters), then
reviewed line by line. Every property access goes through `getP` / `setP`,
which check that the property exists first: a wrong name cannot crash the tool,
it just leaves that slot unset — and a slot left unset on a map is reported in
the Listener.

**First thing to do: run REPORT on a real Blender FBX import and read the
Listener.** That output is the ground truth the open questions below need.

---

## Open questions (to settle with a REPORT on a real import)

| # | Question | Why it matters | Where in the code |
|---|---|---|---|
| 1 | Where does the 3ds Max FBX importer put Blender's roughness map, and with which Inv state? | Blender writes its roughness texture into FBX `ShininessExponent`, a glossiness-style channel. If the importer sets Inv on, the map is read the wrong way round → use *Roughness map is: Roughness*. | `convertMaterial`, roughness |
| 2 | Where does Blender's alpha land: `transparency_map` or `cutout_map`? Inverted or not? | Blender writes alpha into FBX `TransparencyFactor` (its own exporter notes it "will be inverted in fact"). The *Transparency map → Opacity* option assumes the map arrives as-is. | `convertMaterial`, transparency |
| 3 | Does the normal map arrive as a Normal Bump, or as a bare bitmap in the bump slot? Which bump amount? | Decides whether the Normal Bump rebuild or the *named \*normal\** wrap does the work. | `toVRayNormal` |
| 4 | What reflectivity / reflection colour does the importer set? | Blender's specular 0.5 may come in as reflectivity 0.5. The PBR option ignores it on purpose. | reflection block |
| 4b | Does the FBX importer set `flipgreen` on the Normal Bumps it creates? | The OpenGL option adds a flip only where there is none; a flip already set is kept. | `toVRayNormal` |
| 5 | Normal_Bump flags: `flipred` / `flipgreen` / `swap_rg` (Autodesk docs) or `flip_red` / `flip_green` / `swap_red_green` (Lecchi's scripts)? | Both are tried, the first that exists wins. | `toVRayNormal` |
| 6 | `ColorPipelineMgr.mode` and `GetFileIOColorSpaceList()` in OCIO mode, `bm.colorSpace` / `bm.gamma` on a reloaded bitmap | The linear reload checks what Max gives back when it can. A REPORT/CONVERT log saying "gamma 1.0" in an OCIO scene means mode detection failed. | `detectColorMgmt`, `linearize` |
| 7 | VRayMtl names no reference script uses: `refraction_thinWalled`, `texmap_coat_color`, `coat_bump_lock`, `texmap_sheen_multiplier` | Unset slots are reported, nothing breaks. `showProperties (VRayMtl())` settles them. | — |
| 8 | Physical names no reference script uses: `trans_depth`, `emission_map`, `transparency_map`, `coat_color_map`, sheen and thin film names | Same: `showProperties (PhysicalMaterial())`. | — |
| 9 | Physical anisotropy default: 1.0 (isotropic, as V2A implies) or something else? | If the default is not 1.0, every material warns "anisotropy not converted". Noise, not damage. | end of `convertMaterial` |
| 10 | Displacement amount: × 100 here; V2A copies it 1:1 the other way while dividing bump by 100. | One of the two is wrong. A warning asks to check. | displacement block |
| 11 | Are `replaceInstances` and the bitmap reload undone by one Ctrl+Z? | Expected, not verified. | `runTool` |
| 12 | VRayBitmap: default `maptype` and `color_space` of a new one, and are 4 (3ds Max standard) and 0 / 3 (none / from 3ds Max) still those values in V-Ray 7? | The log prints the defaults once per run. Indices taken from Lecchi's scripts (`maptype == 2` is spherical, `color_space` 0 none … 3 from 3ds Max). | `makeVRayBitmap` |
| 13 | VRayBitmap names for `monoOutput`, `rgbOutput`, `alphaSource`, `output`, `coords` | Copied when the names match; a non-default value that cannot be set is warned (alpha cutouts read from the alpha channel depend on it). | `makeVRayBitmap` |
| 14 | VRayUVWRandomizer defaults, and does `mapSource` bypass the VRayBitmap's own tiling? | The randomizer's properties are printed when it is created. A bitmap with non-default tiling gets a warning. | `sharedRandomizer` |

---

## Design decisions (do not undo without a reason)

### Replaced wherever used, with a question first

`replaceInstances` swaps every reference to the Physical, so objects outside
the selection that share it get the VRayMtl too, as do Multi/Sub-Object slots
and Material Editor slots. That is what keeps a shared material shared. The
alternative (assign only on the selection) would split one material in two and
would need to duplicate Multi/Sub-Object materials. Instead the tool counts the
outside users and asks before converting.

### Maps are reused, not copied

The VRayMtl points at the very same map nodes, and the scene does not grow
duplicate maps. Two kinds are rebuilt: Normal Bumps (as VRayNormalMap, a cache
makes a Normal Bump met twice give one VRayNormalMap) and, since 1.1, Bitmaps
(as VRayBitmap, see below). A shared map is never modified in place.

### Roughness convention: follow the Physical, convert values, never maps

Physical has an Inv toggle per roughness; V-Ray has one *Use roughness* switch
for reflection, refraction, coat and sheen. The VRayMtl takes the reflection
convention. Scalar values that use the other convention are converted
(`1 - v`); maps cannot be inverted without adding nodes, so a map in the other
convention gets a warning instead. The untouched V-Ray glossiness defaults are
flipped too when *Use roughness* is on, so they keep meaning "smooth".

### PBR reflection on by default

With Fresnel on, a white reflection and an IOR around 1.5 is what a Principled
BSDF means. A reflection colour below white (an imported reflectivity of 0.5,
say) halves the reflections of every material. The option can be turned off
for hand-made Physicals with a tinted reflection.

### Weights on mapped channels: black swatch + map amount

A V-Ray map amount blends the map with the colour swatch. With a black swatch,
amount = weight × 100 gives map × weight, which is what a Physical weight does
to its map. Used for base weight, reflectivity, transparency and sheen. Not
applied when the map is switched off in the Physical (the swatch must then
carry colour × weight).

### Transparency weight 0 means opaque

A Physical with a transparency colour map but weight 0 renders opaque. The
refraction branch only runs on weight > 0 or a transparency weight map.

### Linear reload is cautious (Bitmaps that stay Bitmaps)

Since 1.1 this only applies when the VRayBitmap option is off, or to a Bitmap
left alone because it is shared outside the run. Only bitmaps found in data
slots are reloaded; one that is also in a colour slot of the run, or used by a
material, a modifier or an object in the scene outside the run, is left as it
is. `linearize` checks what Max gave back (`bm.colorSpace` / `bm.gamma`) when
the bitmap exposes it, and logs "not verifiable" otherwise. Known limit: a
bitmap also used as the environment map is not detected.

Reloading writes the resolved absolute path back into the Bitmap node; the log
says so when the path changed.

### Bitmaps become VRayBitmaps through replaceInstances (1.1)

Swapping each Bitmap for its VRayBitmap with `replaceInstances` reaches it
wherever it sits — directly in a slot, inside a VRayNormalMap we just built,
inside an Output map — and keeps sharing: one Bitmap used by three materials
becomes one VRayBitmap used by the same three. The orphaned Physicals get it
too, harmless. What it must not reach is a user outside the run, so a Bitmap
also used by an in-use material, a modifier (Displace, VRayDisplacementMod) or
a scene object outside the run is left as a Bitmap. Values are copied, not
controllers: animated tiling or output is not carried over.

Transfer function: *none* for data maps, *from 3ds Max* for colour maps (Max's
colour management decides per file, as it did for the Bitmap). A new VRayBitmap
is not trusted to have a sensible default: older VRayHDRI defaulted to inverse
gamma 1.0, made for HDR environments. RGB primaries are left on *Default*:
according to Chaos it converts nothing (unless a file name carries a colour
space tag), which is what data maps need and what colour maps already had.

### One randomizer for every VRayBitmap (1.1)

Asked for by victor.oli. All maps of a material must move together (colour and
normal map misaligned would show at once), and one shared node means one place
to tune it. Plugged through `mapSource`, the way Chaos staff showed on their
forum. Reused by name from one run to the next. Created with V-Ray's defaults,
which the log prints: if they randomize, unwrapped textures (one UV layout per
asset, the usual Blender case) end up misplaced — the log says to check.

### Normal maps: flip green by default (1.1)

V-Ray for 3ds Max reads normal maps as DirectX (Y-), to match 3ds Max's own
Normal Bump; other V-Ray integrations read OpenGL. Chaos staff confirmed it in
March 2026 and decided to keep it that way. Blender writes OpenGL (Y+), so
Blender normal maps need their green flipped. For a Normal Bump, a flip already
set is kept (OR, not XOR: Normal Bump and VRayNormalMap read the same way, so a
Normal Bump that was right stays right). The settings key was renamed so an old
saved *off* does not override the new default.

### No `return` inside `try`

MaxScript implements `return` with an exception, which a surrounding `try` can
swallow. The code uses if/else instead. Keep it that way.

### Emission ratio

Self-illumination multiplier = emission weight × luminance (cd/m²) / 477.464.
477.464 ≈ 1500 / π is the factor Lecchi's V-Ray → Physical converter uses
(`emit_luminance = selfIllumination_multiplier * 477.464`), applied in reverse.

---

## Ideas, not done

- Standard materials (older FBX imports) could get the same treatment.
- Glossiness ↔ roughness map inversion through an Output map, instead of a
  warning, if the import turns out to need it often.
- An option to assign on the selection only, duplicating shared materials.
