# The `_vray.json` file — format 2

What fbx2vray reads. One file per FBX, **same name plus `_vray`, same folder**:
`TABLE_Oak.fbx` → `TABLE_Oak_vray.json`. JSON, UTF-8.

It is written on the Blender side by our exporter (not in this repo), which reads
the **V-Ray for Blender** node graphs of the scene and its V-Ray lights — what an
FBX cannot carry. Anything that writes this format can feed fbx2vray.

**Versions.** Format 2 (English keys, below) is the reference. Format 1 is the
same content with French keys, written by our exporter until November 2026; it
is still read, upgraded on load (mapping at the end). A file is format 1 when it
has `materiaux` and no `materials`, format 2 when it has `materials` (with
`"format": 2`). Unknown keys are ignored, so a writer can add fields without breaking
older readers; a higher `format` number is read as 2, with a warning.

---

## Top level

| Key | Type | |
|---|---|---|
| `format` | int | `2` |
| `name` | string | asset or export name |
| `blend` | string | source `.blend` (information only) |
| `fbx` | string | the FBX this file goes with (information only) |
| `date` | string | `YYYY-MM-DD` |
| `note` | string | free text |
| `rendering_space` | string, optional | colour space the colour values are expressed in. Absent: `ACEScg` |
| `materials` | object | **material name → graph** (below). The name is the one the FBX gives the material: that is how fbx2vray finds it in 3ds Max |
| `lights` | object or `null` | V-Ray lights (below) |
| `fbx_standalone` | object, optional | what the FBX alone carries: `material_ids` (`"1": name`, …), `approximations` (`name: [text]`), `not_exported` (`[text]`). Information only |

Paths (`image.path`, `ies.path`) are **relative to the `_vray.json`** (absolute
paths are accepted). fbx2vray makes them absolute from the file's folder and
checks they exist.

Colour values are **linear, in the rendering space of the source scene**
(`rendering_space`, ACEScg in ours). fbx2vray sets them as they are: a scene
rendering in another space gets other colours (the Listener says so when it can
read the scene's space).

---

## A material: `{source, nodes, links}`

- `source` — string, the `.blend` the material comes from (information only).
- `links` — list of `[from node, from socket, to node, to socket]` (information
  only: the same links are in each node's `inputs`).
- `nodes` — object, **node id → node**. The material's root is what the
  `OutputMaterial` node's `inputs.Material` points to; failing that, the first
  `BRDFVRayMtl`.

### A node

| Key | Type | |
|---|---|---|
| `type` | string | V-Ray plugin name: `BRDFVRayMtl`, `BRDFLight`, `BRDFLayered`, `Mtl2Sided`, `MetaImageTexture`, `TexRemap`, `TexNormalBump`, `UVWGenChannel`… |
| `mute` | bool | node muted in Blender |
| `params` | object | plugin parameters by **V-Ray identifier** (`opacity_source`, `uvw_transform`, `fog_mult`…) |
| `inputs` | object | parameters and sockets by **V-Ray for Blender interface name** (`Diffuse Color`, `Reflection Glossiness`, `Bump Map`…). A plugged socket is a link object (below); an unplugged one holds its value |
| `image` | object | `MetaImageTexture` only (below) |
| `curves` | list | `TexRemap` only: 4 curves (R, G, B, master), each a list of `[x, y, handle]`, handle `"AUTO"` or a type. The curve V-Ray renders |
| `curves_data` | list | `TexRemap`, when Blender's stored curve differs from the rendered one (information only) |

**Link** (a plugged socket): `{"from": node id, "socket": output socket name}`,
plus `"multiplier"` (percent) when the socket multiplier is not 100 (not used
by fbx2vray 1.0).

**`image`**

| Key | Type | |
|---|---|---|
| `path` | string | the image file |
| `color_space` | string | how V-Ray decodes it: `sRGB` (colour) or anything else (`Non-Color`, `Linear`… data, read linear). V-Ray's *auto* mode is resolved by the writer |
| `primaries` | string | `lin_srgb`, `srgb`, `raw`, `acescg`… |
| `transfer` | string | V-Ray transfer function as written by V-Ray for Blender |
| `color_space_blender` | string | Blender's own setting (information only) |
| `size` | `[w, h]` | pixels |
| `exists` | bool | recomputed on read |

---

## `lights`: `{blend, root, frame_range, fps, frame, unit, lights: [...]}`

- `root` — name of the root object of the export; lights without a parent are
  placed relative to it.
- `frame` — the frame the transforms are given at.
- `frame_range` `[first, last]`, `fps`, `unit`, `blend` — information.

### A light

| Key | Type | |
|---|---|---|
| `name` | string | becomes the 3ds Max node name; a light of this name already under the same parent is not created again |
| `plugin` | string | `LightSphere`, `LightRectangle`, `LightIES` (rebuilt); `LightMesh` and others are listed, not rebuilt |
| `bl_type` | string | Blender light type (information) |
| `params` | object | plugin parameters by V-Ray identifier |
| `inputs` | object | by interface name, as for materials; `Color` is the colour V-Ray renders |
| `blender` | object | `color`, `energy`, `radius`, `shape` (`SQUARE`, `RECTANGLE`, `DISK`, `ELLIPSE`), `size`, `size_y` (metres) |
| `ies` | object | `LightIES`: `path`, `exists`, `relative` |
| `parent` | string or `null` | parent object name; the light is attached to the node of that name |
| `parent_type`, `parent_bone` | | Blender parenting (information) |
| `world`, `in_parent`, `in_root` | 4 × 3 | rows: X axis, Y axis, Z axis, position **in metres**, 3ds Max order, at `frame` |
| `keys` | list | animated light: `[[frame, rows], …]`, rows in the parent's space |
| `animated`, `animated_parents` | | Blender animation flags (information; a missing animated parent is reported) |
| `hidden` | bool | hidden from the render in Blender: created off and hidden |
| `props`, `vray_data` | object | Blender custom properties and V-Ray light data (information) |

Sizes in `params` / `inputs` / `blender` are in metres; fbx2vray converts them to
the scene units.

---

## Format 1 → 2

Format 1 has the same structure with these keys. Values are unchanged.

| Where | Format 1 | Format 2 |
|---|---|---|
| top level | `asset` | `name` |
| | `materiaux` | `materials` |
| | `lumieres` (`{}` or `null` when none) | `lights` (`null` when none) |
| | `fbx_autonome` | `fbx_standalone` |
| `fbx_autonome` | `ids_materiaux`, `non_exportes` | `material_ids`, `not_exported` |
| node | `p`, `in` | `params`, `inputs` |
| | `courbes`, `courbes_curves_data` | `curves`, `curves_data` |
| link | `de`, `sortie`, `multiplicateur` | `from`, `socket`, `multiplier` |
| `image` | `chemin`, `cs`, `cs_blender`, `transfert`, `primaires`, `taille`, `existe` | `path`, `color_space`, `color_space_blender`, `transfer`, `primaries`, `size`, `exists` |
| `lumieres` | `fichier`, `racine`, `plage`, `image`, `unite`, `lumieres` | `blend`, `root`, `frame_range`, `frame`, `unit`, `lights` |
| light | `nom`, `cache`, `anime`, `cles`, `monde`, `dans_parent`, `dans_racine`, `image`, `p`, `prises`, `parents_animes` | `name`, `hidden`, `animated`, `keys`, `world`, `in_parent`, `in_root`, `frame`, `params`, `inputs`, `animated_parents` |
| light `blender` | `couleur`, `energie`, `forme`, `rayon`, `taille`, `taille_y` | `color`, `energy`, `shape`, `radius`, `size`, `size_y` |
| light `ies` | `chemin`, `existe`, `relatif` | `path`, `exists`, `relative` |

The mapping lives in `fbx2vray.py` (`upgrade_v1`): change it there, then here.
