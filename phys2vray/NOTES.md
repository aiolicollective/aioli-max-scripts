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
| 5 | Normal_Bump flags: `flipred` / `flipgreen` / `swap_rg` (Autodesk docs) or `flip_red` / `flip_green` / `swap_red_green` (Lecchi's scripts)? | Both are tried, the first that exists wins. | `toVRayNormal` |
| 6 | `ColorPipelineMgr.mode` and `GetFileIOColorSpaceList()` in OCIO mode, `bm.colorSpace` / `bm.gamma` on a reloaded bitmap | The linear reload checks what Max gives back when it can. A REPORT/CONVERT log saying "gamma 1.0" in an OCIO scene means mode detection failed. | `detectColorMgmt`, `linearize` |
| 7 | VRayMtl names no reference script uses: `refraction_thinWalled`, `texmap_coat_color`, `coat_bump_lock`, `texmap_sheen_multiplier` | Unset slots are reported, nothing breaks. `showProperties (VRayMtl())` settles them. | — |
| 8 | Physical names no reference script uses: `trans_depth`, `emission_map`, `transparency_map`, `coat_color_map`, sheen and thin film names | Same: `showProperties (PhysicalMaterial())`. | — |
| 9 | Physical anisotropy default: 1.0 (isotropic, as V2A implies) or something else? | If the default is not 1.0, every material warns "anisotropy not converted". Noise, not damage. | end of `convertMaterial` |
| 10 | Displacement amount: × 100 here; V2A copies it 1:1 the other way while dividing bump by 100. | One of the two is wrong. A warning asks to check. | displacement block |
| 11 | Are `replaceInstances` and the bitmap reload undone by one Ctrl+Z? | Expected, not verified. | `runTool` |

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

The VRayMtl points at the very same map nodes. Tiling, crop, output curves,
real-world scale all come along, and the scene does not grow duplicate maps.
Only Normal Bumps are rebuilt (as VRayNormalMap), and a cache makes a Normal
Bump met twice give one VRayNormalMap.

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

### Linear reload is cautious

Only bitmaps found in data slots are reloaded; one that is also in a colour slot
of the run, or used by a material in the scene that is not part of the run, is
left as it is. `linearize` checks what Max gave back (`bm.colorSpace` /
`bm.gamma`) when the bitmap exposes it, and logs "not verifiable" otherwise.
Known limit: a bitmap also used outside any material (Displace modifier,
environment, projector light) is not detected.

Reloading writes the resolved absolute path back into the Bitmap node; the log
says so when the path changed.

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
