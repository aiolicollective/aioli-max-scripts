"""fbx2vray.py -- 3ds Max (pymxs): rebuilds the exact V-Ray materials and lights of an FBX from its `<name>_vray.json`.

Part of aioli-max-scripts (https://github.com/aiolicollective/aioli-max-scripts), MIT licence.
Version 1.0 (in test). Written by the /ai.oli collective with AI assistance, 2026-11-02, from the
script our asset library has used since 2026-10-27 (tried in 3ds Max 2026 / V-Ray 7 on a library asset:
11 materials, 11 lights, dimensions right).

The FBX carries the geometry; the `<name>_vray.json` written next to it by our Blender-side exporter carries
what an FBX cannot: the V-Ray for Blender node graphs of every material, and the V-Ray lights. This script reads
that file and rebuilds each material in 3ds Max with the matching V-Ray classes (VRayMtl, VRayLightMtl,
VRayBlendMtl, VRay2SidedMtl, VRayBitmap, VRayNormalMap, VRayDirt, ...), finding the materials by name.
The file format is described in FORMAT.md; versions 1 (French keys) and 2 (English keys) are both read.

Two actions, from the panel of aioli-fbx2vray.ms (which runs this file again at every click):
  import   pick an FBX: with a `<name>_vray.json` next to it, the FBX is imported and its materials and lights
           rebuilt; without one, the FBX is imported, what came in is selected and phys2vray opens
           (CONVERT TO V-RAY: generic Physical -> VRayMtl).
  apply    pick a `_vray.json`: its materials replace those of the same name on the selection and its children
           (an FBX imported earlier with File > Import). Nothing selected: the whole scene, after a question.
A V-Ray material with the same name already in the scene: ask, reuse it, or rebuild it from the file
(everywhere it is used). Materials and lights are created in a single undo; the FBX import itself cannot be undone.
Run on its own (Scripting > Run Script), this file does `import`, asking about existing V-Ray materials.

Every property is set through a check: a wrong property name does not stop the run, it is listed in the
Listener as a "!" line, and the rest goes on.
"""
import json, os, traceback
import pymxs
from pymxs import runtime as rt

VERSION = "1.0"
TOOL = "aioli-fbx2vray"
WARN = []
VRAY_MTLS = ("VRayMtl", "VRayLightMtl", "VRayBlendMtl", "VRay2SidedMtl")


def _log(s):
    print(f"[{TOOL}] {s}")


# =====================================================================================================
# FILE FORMAT -- version 2 (English keys) is what the code reads; version 1 (French keys, written by our
# library until 2026-11) is upgraded on load. Key tables below = the v1 -> v2 mapping documented in FORMAT.md.
# =====================================================================================================

TOP_V1 = {"asset": "name", "materiaux": "materials", "lumieres": "lights", "fbx_autonome": "fbx_standalone"}
NODE_V1 = {"p": "params", "in": "inputs", "courbes": "curves", "courbes_curves_data": "curves_data"}
LINK_V1 = {"de": "from", "sortie": "socket", "multiplicateur": "multiplier"}
IMAGE_V1 = {"chemin": "path", "cs": "color_space", "cs_blender": "color_space_blender", "transfert": "transfer",
            "primaires": "primaries", "taille": "size", "existe": "exists"}
LIGHTS_V1 = {"fichier": "blend", "racine": "root", "plage": "frame_range", "image": "frame", "unite": "unit",
             "lumieres": "lights"}
LIGHT_V1 = {"nom": "name", "cache": "hidden", "anime": "animated", "cles": "keys", "dans_parent": "in_parent",
            "dans_racine": "in_root", "monde": "world", "image": "frame", "p": "params", "prises": "inputs",
            "parents_animes": "animated_parents"}
LIGHT_BLENDER_V1 = {"couleur": "color", "energie": "energy", "forme": "shape", "rayon": "radius", "taille": "size",
                    "taille_y": "size_y"}
IES_V1 = {"chemin": "path", "existe": "exists", "relatif": "relative"}
STANDALONE_V1 = {"ids_materiaux": "material_ids", "non_exportes": "not_exported"}


def _rename(d, table):
    """same dict, keys renamed by the table, unknown keys kept as they are"""
    return {table.get(k, k): v for k, v in d.items()}


def _link_v1(v):
    return _rename(v, LINK_V1) if isinstance(v, dict) and "de" in v else v


def _node_v1(n):
    o = _rename(n, NODE_V1)
    if isinstance(o.get("inputs"), dict):
        o["inputs"] = {k: _link_v1(v) for k, v in o["inputs"].items()}
    if isinstance(o.get("image"), dict):
        o["image"] = _rename(o["image"], IMAGE_V1)
    return o


def _light_v1(e):
    o = _rename(e, LIGHT_V1)
    if isinstance(o.get("inputs"), dict):
        o["inputs"] = {k: _link_v1(v) for k, v in o["inputs"].items()}
    if isinstance(o.get("blender"), dict):
        o["blender"] = _rename(o["blender"], LIGHT_BLENDER_V1)
    if isinstance(o.get("ies"), dict):
        o["ies"] = _rename(o["ies"], IES_V1)
    return o


def upgrade_v1(d):
    """format 1 (French keys) -> format 2 (English keys); values are not touched"""
    o = _rename(d, TOP_V1)
    o["format"] = 2
    o["materials"] = {}
    for k, g in (d.get("materiaux") or {}).items():
        gg = dict(g)
        gg["nodes"] = {nk: _node_v1(n) for nk, n in (g.get("nodes") or {}).items()}
        o["materials"][k] = gg
    L = d.get("lumieres")
    if L:
        L = _rename(L, LIGHTS_V1)
        L["lights"] = [_light_v1(e) for e in L.get("lights") or []]
    o["lights"] = L or None
    fs = d.get("fbx_autonome")
    if isinstance(fs, dict):
        o["fbx_standalone"] = _rename(fs, STANDALONE_V1)
    return o


def _absolute(d, base):
    """relative paths of the file (images, IES) -> absolute from its folder; 'exists' computed again"""
    def fix(o):
        if isinstance(o, dict):
            p = o.get("path")
            if isinstance(p, str) and p:
                if not os.path.isabs(p):
                    o["path"] = os.path.normpath(os.path.join(base, p))
                if "exists" in o:
                    o["exists"] = os.path.exists(o["path"])
    for g in (d.get("materials") or {}).values():
        for n in (g.get("nodes") or {}).values():
            fix(n.get("image"))
    for e in ((d.get("lights") or {}).get("lights") or []):
        fix(e.get("ies"))
    return d


def read_vray_json(path):
    """the file, as format 2 with absolute paths; ValueError if it is not a _vray.json"""
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError(f"{os.path.basename(path)} is not a _vray.json")
    fmt = d.get("format")
    if "materiaux" in d and "materials" not in d:
        d = upgrade_v1(d); read_as = 1
    elif "materials" in d:
        read_as = 2
        if isinstance(fmt, int) and fmt > 2:
            WARN.append(f"{os.path.basename(path)}: format {fmt}, newer than this script (2): read as 2, update the clone")
    else:
        raise ValueError(f"{os.path.basename(path)} is not a _vray.json (no 'materials')")
    d["materials"] = d.get("materials") or {}
    d["lights"] = d.get("lights") or None
    d["_read_as"] = read_as
    return _absolute(d, os.path.dirname(os.path.abspath(path)))


# =====================================================================================================
# SMALL HELPERS
# =====================================================================================================

def _set(o, prop, v):
    try:
        setattr(o, prop, v); return True
    except Exception as e:
        WARN.append(f"{o} .{prop} = {v!r} : {e}"); return False


def _set_first(o, props, v, what):
    """first property name accepted among several (3ds Max names not confirmed); listed if none"""
    for p in props:
        try:
            setattr(o, p, v); return True
        except Exception:
            continue
    WARN.append(f"{o} : {what} not set ({' / '.join(props)})"); return False


def _color(c):
    return rt.Color(*(max(0.0, float(x)) * 255.0 for x in c[:3]))


def _mean(v, d=1.0):
    if isinstance(v, (list, tuple)):
        return float(sum(float(x) for x in v[:3]) / len(v[:3]))
    return float(v) if v is not None else d


def _descendants(n, acc):
    acc.append(n)
    for c in n.children:
        _descendants(c, acc)
    return acc


def _units_per_metre():
    """scene units per metre (cm -> 100)"""
    try:
        return float(rt.units.decodeValue("1m"))
    except Exception:
        WARN.append("scene units not read: 100 per metre assumed (cm)"); return 100.0


def root_node(N):
    out = next((v for v in N.values() if v["type"] == "OutputMaterial"), None)
    l = out["inputs"].get("Material") if out else None
    if isinstance(l, dict) and l["from"] in N:
        return l["from"]
    return next(k for k, v in N.items() if v["type"] == "BRDFVRayMtl")


# =====================================================================================================
# MATERIALS -- one Builder per material: the V-Ray for Blender graph -> 3ds Max V-Ray classes
# =====================================================================================================

class Builder:
    def __init__(self, name, g, u):
        self.name = name; self.N = g["nodes"]; self.cache = {}; self.u = u

    # --- coordinates ---
    def _uvw_node(self, mapping):
        """mapping node (after a UVWGenRandomizer, if any)"""
        if not isinstance(mapping, dict):
            return {}
        n = self.N.get(mapping["from"], {})
        if n.get("type") == "UVWGenRandomizer":
            WARN.append(f"{self.name} : random variation per tile (UVWGenRandomizer) not carried over")
            m = n["inputs"].get("Input"); n = self.N.get(m["from"], {}) if isinstance(m, dict) else {}
        return n

    def uv(self, bm, mapping):
        n = self._uvw_node(mapping)
        if n.get("type") == "UVWGenChannel":
            t = n["params"].get("uvw_transform") or [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            su = (t[0] ** 2 + t[1] ** 2) ** 0.5; sv = (t[4] ** 2 + t[5] ** 2) ** 0.5
            tr = n["inputs"].get("Uvw Transform")
            if isinstance(tr, dict):
                tn = self.N[tr["from"]]["inputs"]; su, sv = float(tn["Scale"][0]), float(tn["Scale"][1])
                if any(abs(float(x)) > 1e-6 for x in tn.get("Offset", [0, 0, 0])[:2]):
                    WARN.append(f"{self.name} : UV offset not carried over")
            _set(bm.coords, "U_Tiling", su); _set(bm.coords, "V_Tiling", sv)
            _set(bm.coords, "mapChannel", int(n["params"].get("uvw_channel", 1)))
        elif n.get("type") in ("UVWGenObject", "UVWMapping"):          # planar projection from the object (bitmap)
            _set(bm.coords, "mapping", 2)
            WARN.append(f"{self.name} : bitmap in object coordinates ({n['type']}): planar from object, to check")

    def xyz(self, r, mapping, size_m=None, size_prop="size"):
        """3D map (Noise, Cellular): XYZ object coordinates or UV channel; size in metres -> scene units in XYZ"""
        n = self._uvw_node(mapping)
        if n.get("type") == "UVWGenChannel":
            _set(r.coords, "coordType", 2); _set(r.coords, "mapChannel", int(n["params"].get("uvw_channel", 1)))
            if size_m is not None:
                _set(r, size_prop, float(size_m))
            return
        _set(r.coords, "coordType", 0)      # XYZ object, UVWMapping too (world, offset, in V-Ray): the pattern follows the moved object
        if n.get("type") == "UVWMapping":
            WARN.append(f"{self.name} : UVWMapping (world in V-Ray) set as XYZ object, offset not carried over")
        t = n.get("params", {}).get("uvw_transform")
        if t:
            s = [(t[0] ** 2 + t[1] ** 2 + t[2] ** 2) ** 0.5, (t[4] ** 2 + t[5] ** 2 + t[6] ** 2) ** 0.5, (t[8] ** 2 + t[9] ** 2 + t[10] ** 2) ** 0.5]
            if any(abs(x - 1) > 1e-4 for x in s):
                _set(r.coords, "tiling", rt.Point3(*s))
        if size_m is not None:
            _set(r, size_prop, float(size_m) * self.u)

    def input(self, n, key, default, channel):
        """(map, colour) of an input: the map if one is plugged, the colour otherwise"""
        v = n["inputs"].get(key, default)
        if isinstance(v, dict):
            return self.map(v, channel), None
        return None, v

    def color_or_map(self, r, n, key, default, color_prop, map_prop, channel, on_prop=None):
        m, v = self.input(n, key, default, channel)
        if m is not None:
            _set(r, map_prop, m)
            if on_prop:
                _set(r, on_prop, True)
        elif v is not None:
            _set(r, color_prop, _color(v) if isinstance(v, (list, tuple)) else float(v))

    def _output(self, r, p):
        """common output settings (multiplier, offset, invert) on the map's 3ds Max Output"""
        cm = _mean(p.get("color_mult", [1, 1, 1])); co = _mean(p.get("color_offset", [0, 0, 0]))
        try:
            if abs(cm - 1) > 1e-6:
                _set(r.output, "RGB_Level", cm)
            if abs(co) > 1e-6:
                _set(r.output, "RGB_Offset", co)
            if p.get("invert"):
                _set(r.output, "invert", True)
        except Exception:
            pass

    def mix_curve(self, f, pts):
        """Falloff mix curve from the TexRemap points (auto handles -> Catmull-Rom tangents)"""
        try:
            crv = f.mixCurve.curves[0]
            n = len(pts)
            def tang(i):
                a = pts[max(i - 1, 0)]; b = pts[min(i + 1, n - 1)]
                return (b[1] - a[1]) / max(b[0] - a[0], 1e-6)
            crv.points[0].value = rt.Point2(float(pts[0][0]), float(pts[0][1]))
            crv.points[int(crv.numPoints) - 1].value = rt.Point2(float(pts[-1][0]), float(pts[-1][1]))     # numPoints: points of the curve
            for i in range(1, n - 1):
                x, y = float(pts[i][0]), float(pts[i][1]); s = tang(i)
                dp = (x - float(pts[i - 1][0])) / 3.0; dn = (float(pts[i + 1][0]) - x) / 3.0
                p = rt.ccPoint(rt.Point2(x, y), rt.Point2(-dp, -s * dp), rt.Point2(dn, s * dn), bezier=True)
                rt.insertPoint(crv, i + 1, p)
            return True
        except Exception as e:
            WARN.append(f"{self.name} : Falloff mix curve not set ({e}); set it by hand: "
                        + ", ".join(f"({round(float(x), 3)} ; {round(float(y), 3)})" for x, y, *_ in pts))
            return False

    # --- maps ---
    def map(self, link, channel):
        """3ds Max map for a plugged input; None if it cannot be rebuilt"""
        k = link["from"]
        if k in self.cache:
            return self.cache[k]
        n = self.N[k]; t = n["type"]; p = n.get("params", {}); r = None
        if t == "MetaImageTexture":
            im = n["image"]; r = rt.VRayBitmap(); r.name = os.path.splitext(os.path.basename(im["path"]))[0]
            _set(r, "HDRIMapName", im["path"])
            # same settings as phys2vray 1.6: colour = sRGB transfer (2) + sRGB primaries (1); data = none (0) + Raw (3).
            # V-Ray's auto mode is resolved by the exporter: an 8-bit image read in auto (roughness in a JPEG...) stays
            # sRGB, as it was rendered.
            if im["color_space"] == "sRGB":
                _set(r, "color_space", 2); _set(r, "rgbColorSpace", 1 if im.get("primaries") in (None, "lin_srgb", "srgb") else 0)
            else:
                _set(r, "color_space", 0); _set(r, "rgbColorSpace", 3)
            self.uv(r, n["inputs"].get("Mapping"))
            if p.get("invert"):
                _set(r.output, "invert", True)
        elif t in ("TexCombineFloat", "TexCombineColor"):
            src = n["inputs"].get("Texture")
            r = self.map(src, channel) if isinstance(src, dict) else None
            tm = float(n["inputs"].get("Texture Multiplier", 1.0)); rm = float(n["inputs"].get("Result Multiplier", 1.0))
            if r is not None and (abs(tm - 1) > 1e-6 or abs(rm - 1) > 1e-6 or p.get("result_invert")):
                # V-Ray: (texture x tm + value x (1 - tm)) x rm, inverted if asked -> Mix (value, texture, tm) then Output
                x = r
                if abs(tm - 1) > 1e-6:
                    key = "Value" if t == "TexCombineFloat" else "Color"
                    v = n["inputs"].get(key, 0.0 if t == "TexCombineFloat" else [0, 0, 0])
                    mx = rt.Mix(); mx.name = f"{self.name}_{channel}_combine"
                    _set(mx, "color1", _color(v if isinstance(v, (list, tuple)) else [v, v, v])); _set(mx, "map2", x)
                    _set(mx, "mixAmount", 100.0 * tm); x = mx
                r = rt.Output(); r.name = f"{self.name}_{channel}_combine_output"; _set(r, "map1", x)
                _set(r.output, "output_amount", rm)
                if p.get("result_invert"):
                    _set(r.output, "invert", True)
        elif t == "TexCombineColorLightMtl":
            src = n["inputs"].get("Texture"); m = self.map(src, channel) if isinstance(src, dict) else None
            rm = float(n["inputs"].get("Result Multiplier", 1.0))
            if m is None:
                r = rt.VRayColor(); _set(r, "color", _color(src if isinstance(src, (list, tuple)) else [1, 1, 1])); _set(r, "rgb_multiplier", rm)
            elif abs(rm - 1) > 1e-6:
                r = rt.Output(); r.name = f"{self.name}_{channel}_light"; _set(r, "map1", m); _set(r.output, "output_amount", rm)
            else:
                r = m
        elif t == "TexOutput":
            src = n["inputs"].get("Texture"); m = self.map(src, channel) if isinstance(src, dict) else None
            cm = p.get("color_mult", [1, 1, 1]); co = p.get("color_offset", [0, 0, 0]); om = p.get("output_mult", [1, 1, 1])
            neutral = not p.get("invert") and all(abs(x - 1) < 1e-6 for x in cm[:3] + om[:3]) and all(abs(x) < 1e-6 for x in co[:3])
            if m is None or neutral:
                r = m
            else:                     # V-Ray: (x * mult + offset), invert, * output multiplier
                r = rt.Output(); r.name = f"{self.name}_{channel}_output"; _set(r, "map1", m)
                _set(r.output, "RGB_Level", float(sum(cm[:3]) / 3)); _set(r.output, "RGB_Offset", float(sum(co[:3]) / 3))
                _set(r.output, "invert", bool(p.get("invert"))); _set(r.output, "output_amount", float(sum(om[:3]) / 3))
                if p.get("invert") and (abs(sum(cm[:3]) / 3 - 1) > 1e-6 or abs(sum(co[:3]) / 3) > 1e-6):
                    WARN.append(f"{self.name} / {channel} : inverted output with level / offset: order of operations to check")
        elif t == "TexRemap":
            src = n["inputs"].get("Input Color"); m = self.map(src, channel) if isinstance(src, dict) else None
            cv = n.get("curves") or []
            line = [c for c in cv if not (len(c) == 2 and abs(c[0][0]) < 1e-6 and abs(c[0][1]) < 1e-6 and abs(c[1][0] - 1) < 1e-6 and abs(c[1][1] - 1) < 1e-6)]
            if m is None:
                r = None
            elif not line:
                r = m
            elif len(line) == 1 and len(line[0]) == 2 and abs(line[0][0][0]) < 1e-6 and abs(line[0][1][0] - 1) < 1e-6:
                y0, y1 = float(line[0][0][1]), float(line[0][1][1])
                r = rt.Output(); r.name = f"{self.name}_{channel}_curve"; _set(r, "map1", m)
                _set(r.output, "RGB_Level", y1 - y0); _set(r.output, "RGB_Offset", y0)
            else:
                WARN.append(f"{self.name} / {channel} : non-linear TexRemap curve not carried over"); r = m
        elif t == "ColorCorrection":
            src = n["inputs"].get("Source Color"); m = self.map(src, channel) if isinstance(src, dict) else None
            r = rt.Color_Correction(); r.name = f"{self.name}_{channel}_correction"
            if m is not None:
                _set(r, "map", m)
            else:
                sc = n["inputs"].get("Source Color")
                if isinstance(sc, list):
                    _set(r, "color", _color(sc))
            if [str(p.get(k)) for k in ("rewire_red", "rewire_green", "rewire_blue")] != ["0", "1", "2"]:
                WARN.append(f"{self.name} / {channel} : channel rewiring not carried over")
            _set(r, "hueShift", float(p.get("hue_shift", 0)))
            _set(r, "saturation", 100.0 * float(p.get("saturation", 0)))
            _set(r, "tint", _color(p.get("hue_tint", [0, 0, 0]))); _set(r, "tintStrength", 100.0 * float(p.get("tint_strength", 0)))
            if str(p.get("lightness_mode")) == "1":
                _set(r, "lightnessMode", 1); _set(r, "exposureMode", int(p.get("adv_exposure_mode", 0)))
                _set(r, "gainRGB", 100.0 * float(p["adv_brightness"])); _set(r, "gammaRGB", float(p["adv_contrast"]))
                _set(r, "pivotRGB", float(p["adv_base"])); _set(r, "liftRGB", float(p["adv_offset"]))
                for i, c in enumerate("RGB"):
                    if p.get(("adv_use_red", "adv_use_green", "adv_use_blue")[i]):
                        _set(r, "enable" + c, True)
                        _set(r, "gain" + c, 100.0 * float(p["adv_rgb_brightness"][i])); _set(r, "gamma" + c, float(p["adv_rgb_contrast"][i]))
                        _set(r, "pivot" + c, float(p["adv_rgb_base"][i])); _set(r, "lift" + c, float(p["adv_rgb_offset"][i]))
            else:
                _set(r, "lightnessMode", 0)
                _set(r, "brightness", 100.0 * float(p.get("brightness", 0))); _set(r, "contrast", 100.0 * (float(p.get("contrast", 1)) - 1))
        elif t == "TexNormalBump":
            src = n["inputs"].get("Map"); m = self.map(src, channel) if isinstance(src, dict) else None
            mt = str(p.get("map_type"))
            if mt == "1" and m is not None:
                r = rt.VRayNormalMap(); _set(r, "normal_map", m); _set(r, "normal_map_on", True)
                _set(r, "flip_green", bool(p.get("flip_green"))); _set(r, "flip_red", bool(p.get("flip_red")))
                _set(r, "swap_redgreen", bool(p.get("swap_red_green")))
                _set(r, "normal_map_multiplier", 1.0)
            elif mt == "0" and m is not None:          # nested bump of type 0: image passed on as it is
                WARN.append(f"{self.name} : nested bump of type 0: image passed on as it is"); r = m
            else:
                WARN.append(f"{self.name} : bump of type {mt} not carried over"); r = None
        elif t == "TexFalloff":
            r = rt.Falloff(); r.name = f"{self.name}_{channel}_falloff"
            _set(r, "type", int(n["inputs"].get("Type", p.get("type", 1))))
            _set(r, "direction", int(n["inputs"].get("Direction Type", p.get("direction_type", 0))))
            self.color_or_map(r, n, "Front Color", p.get("color1", [1, 1, 1]), "color1", "map1", channel, "map1On")
            self.color_or_map(r, n, "Side Color", p.get("color2", [0, 0, 0]), "color2", "map2", channel, "map2On")
            _set(r, "ior", float(n["inputs"].get("Fresnel IOR", p.get("fresnel_ior", 1.6))))
            if str(n["inputs"].get("Type", p.get("type"))) == "4":
                _set(r, "nearDistance", float(p.get("dist_near", 0)) * self.u); _set(r, "farDistance", float(p.get("dist_far", 100)) * self.u)
                _set(r, "extrapolateOn", bool(p.get("dist_extrapolate")))
            bi = n["inputs"].get("Blend Input")
            if (n["inputs"].get("Use Blend Input", p.get("use_blend_input"))) and isinstance(bi, dict):
                nb = self.N.get(bi["from"], {})
                cv = nb.get("curves") or []
                if nb.get("type") == "TexRemap" and cv:
                    if any(not (len(c) == 2 and abs(c[0][1]) < 1e-6 and abs(c[1][1] - 1) < 1e-6) for c in cv[:3]):
                        WARN.append(f"{self.name} : mix curve per channel: master curve only")
                    pts = cv[3]
                    if not (len(pts) == 2 and abs(pts[0][1]) < 1e-6 and abs(pts[1][1] - 1) < 1e-6):
                        self.mix_curve(r, pts)
                else:
                    WARN.append(f"{self.name} : falloff mix driven by {nb.get('type')}: not carried over")
            self._output(r, p)
        elif t == "TexDirt":
            r = rt.VRayDirt(); r.name = f"{self.name}_{channel}_dirt"
            _set(r, "radius", float(n["inputs"].get("Radius", p.get("radius", 0.1))) * self.u)
            self.color_or_map(r, n, "Occluded Color", p.get("black_color", [0, 0, 0]), "occluded_color", "texmap_occluded_color", channel)
            self.color_or_map(r, n, "Unoccluded Color", p.get("white_color", [1, 1, 1]), "unoccluded_color", "texmap_unoccluded_color", channel)
            for k, key in (("distribution", "Distribution"), ("falloff", "Falloff"), ("subdivs", "Subdivs"), ("glossiness", "Glossiness")):
                v = n["inputs"].get(key, p.get(k))
                if v is not None and not isinstance(v, dict):
                    _set(r, k, float(v) if k != "subdivs" else int(v))
            for k in ("bias_x", "bias_y", "bias_z"):
                _set(r, k, float(p.get(k, 0)) * self.u)
            for k in ("ignore_for_gi", "consider_same_object_only", "invert_normal", "double_sided", "work_with_transparency",
                      "ignore_self_occlusion", "affect_alpha", "environment_occlusion", "affect_reflection_elements", "thin_mode"):
                if k in p:
                    _set(r, k, bool(p[k]))
            _set(r, "mode", int(p.get("mode", 0)))
        elif t == "TexNoiseMax":
            r = rt.Noise(); r.name = f"{self.name}_{channel}_noise"
            _set(r, "type", int(p.get("type", 0)))
            self.color_or_map(r, n, "Color 1", p.get("color1", [0, 0, 0]), "color1", "map1", channel, "map1On")
            self.color_or_map(r, n, "Color 2", p.get("color2", [1, 1, 1]), "color2", "map2", channel, "map2On")
            _set(r, "phase", float(p.get("phase", 0))); _set(r, "levels", float(p.get("iterations", 3)))
            _set(r, "thresholdLow", float(p.get("low", 0))); _set(r, "thresholdHigh", float(p.get("high", 1)))
            self.xyz(r, n["inputs"].get("Mapping"), p.get("size", 1.0))
            self._output(r, p)
        elif t == "TexCellular":
            r = rt.Cellular(); r.name = f"{self.name}_{channel}_cellular"
            self.color_or_map(r, n, "Center Color", p.get("center_color", [1, 1, 1]), "cellColor", "cellMap", channel)
            self.color_or_map(r, n, "Edge Color", p.get("edge_color", [0.5, 0.5, 0.5]), "divColor1", "divMap1", channel)
            self.color_or_map(r, n, "Background Color", p.get("bg_color", [0, 0, 0]), "divColor2", "divMap2", channel)
            _set(r, "spread", float(p.get("spread", 0.5))); _set(r, "type", int(p.get("type", 0)))
            _set(r, "lowThresh", float(p.get("low", 0))); _set(r, "midThresh", float(p.get("middle", 0.5))); _set(r, "highThresh", float(p.get("high", 1)))
            _set(r, "fractal", bool(p.get("fractal"))); _set(r, "iteration", float(p.get("fractal_iterations", 3)))
            _set(r, "roughness", float(p.get("fractal_roughness", 0)))
            self.xyz(r, n["inputs"].get("Mapping"), p.get("size", 5.0))
            self._output(r, p)
        elif t == "TexMix":
            r = rt.Mix(); r.name = f"{self.name}_{channel}_mix"
            self.color_or_map(r, n, "Color 1", p.get("color1", [1, 1, 1]), "color1", "map1", channel, "map1Enabled")
            self.color_or_map(r, n, "Color 2", p.get("color2", [0, 0, 0]), "color2", "map2", channel, "map2Enabled")
            mm = n["inputs"].get("Mix Map")
            if isinstance(mm, dict):
                x = self.map(mm, channel)
                if x is not None:
                    _set(r, "mask", x); _set(r, "maskEnabled", True)
            _set(r, "mixAmount", 100.0 * float(n["inputs"].get("Mix Amount", p.get("mix_amount", 0))))
            if n["inputs"].get("Use Curve", p.get("use_curve")):
                _set(r, "useCurve", True); _set(r, "lower", float(p.get("transition_lower", 0.3))); _set(r, "upper", float(p.get("transition_upper", 0.7)))
            self._output(r, p)
        elif t == "TexTiles":
            r = rt.Tiles(); r.name = f"{self.name}_{channel}_tiles"
            for props, v, what in (
                    (("Tile_Type", "preset_type", "tileType"), int(p.get("pattern_type", 0)), "pattern"),
                    (("Brick_Color", "tile_color", "Tile_Color"), _color(p.get("color_tiles", [0.5, 0.5, 0.5])), "tile colour"),
                    (("Mortar_Color", "mortar_color"), _color(p.get("color_mortar", [0.2, 0.2, 0.2])), "mortar colour"),
                    (("Horizontal_Count", "horizontal_count"), float(p.get("horizontal_count", 4)), "horizontal count"),
                    (("Vertical_Count", "vertical_count"), float(p.get("vertical_count", 4)), "vertical count"),
                    (("Color_Variance", "color_variance"), float(p.get("color_variance", 0)), "colour variance"),
                    (("Fade_Variance", "fade_variance"), float(p.get("fade_variance", 0)), "fade variance"),
                    (("Horizontal_Gap", "horizontal_gap"), float(p.get("horizontal_gap", 0.5)), "horizontal gap"),
                    (("Vertical_Gap", "vertical_gap"), float(p.get("vertical_gap", 0.5)), "vertical gap"),
                    (("Holes", "holes"), int(p.get("holes", 0)), "holes"),
                    (("Edge_Roughness", "edge_roughness"), float(p.get("edge_roughness", 0)), "edge roughness"),
                    (("Random_Seed", "random_seed"), int(p.get("random_seed", 0)), "random seed"),
                    (("Line_Shift", "line_shift"), float(p.get("line_shift", 0.5)), "line shift"),
                    (("Random_Shift", "random_shift"), float(p.get("random_shift", 0)), "random shift")):
                _set_first(r, props, v, what)
            self.uv(r, n["inputs"].get("Mapping"))
            self._output(r, p)
        elif t == "TexTriPlanar":
            r = rt.VRayTriplanarTex(); r.name = f"{self.name}_{channel}_triplanar"
            _set(r, "texture_mode", int(p.get("texture_mode", 0)))
            for key, props in (("Texture X", ("texture", "texture_x")), ("Texture Y", ("texture_y",)), ("Texture Z", ("texture_z",))):
                v = n["inputs"].get(key)
                if isinstance(v, dict):
                    x = self.map(v, channel)
                    if x is not None:
                        _set_first(r, props, x, key)
            _set(r, "size", float(p.get("size", 1.0)) * self.u); _set(r, "scale", float(p.get("scale", 1.0)))
            _set(r, "blend", float(p.get("blend", 0.2)))
            tr = p.get("texture_rotation")
            if tr:
                _set(r, "texture_rotation", rt.Point3(*[float(x) for x in tr[:3]]))
            for k in ("random_texture_offset", "random_texture_rotation", "random_axis", "random_frame_rotation"):
                _set(r, k, bool(p.get(k)))
            _set(r, "space", int(p.get("ref_space", 0)))
        elif t == "TexMulti":
            r = rt.VRayMultiSubTex(); r.name = f"{self.name}_{channel}_multi"
            i = 1; maps = []
            while f"Texture {i}" in n["inputs"]:
                v = n["inputs"][f"Texture {i}"]
                maps.append(self.map(v, channel) if isinstance(v, dict) else None); i += 1
            if p.get("random_mode_scene_name") or p.get("random_mode_node_name"):
                WARN.append(f"{self.name} : VRayMultiSubTex: random pick by object name, mode to check")
            _set(r, "mode", int(p.get("mode", 0)))
            try:
                r.texmap = rt.Array(*[m for m in maps])
            except Exception:
                ok = False
                for j, m in enumerate(maps):
                    ok = _set_first(r, (f"texmap{j + 1}", f"texmap_{j + 1}"), m, f"texture {j + 1}") or ok
                if not ok:
                    WARN.append(f"{self.name} : VRayMultiSubTex textures to plug by hand ({len(maps)})")
        elif t == "TexLayeredMax":
            r = rt.CompositeTexturemap(); r.name = f"{self.name}_{channel}_layers"
            maps, masks, modes, ops = [], [], [], []
            i = 1
            while f"Texture {i}" in n["inputs"]:
                v = n["inputs"][f"Texture {i}"]
                if isinstance(v, dict):
                    maps.append(self.map(v, channel))
                    mk = n["inputs"].get(f"Mask {i}"); masks.append(self.map(mk, channel) if isinstance(mk, dict) else None)
                    modes.append(int(n["inputs"].get(f"Blend Mode {i}", 0))); ops.append(100.0 * float(n["inputs"].get(f"Opacity {i}", 1.0)))
                i += 1
            try:
                r.mapList = rt.Array(*maps); r.mask = rt.Array(*masks); r.blendMode = rt.Array(*modes); r.opacity = rt.Array(*ops)
            except Exception as e:
                WARN.append(f"{self.name} / {channel} : Composite layers not set ({e}): {len(maps)} layers, modes {modes}, opacities {ops}")
        else:
            WARN.append(f"{self.name} / {channel} : node {t} not rebuilt")
            r = None
        self.cache[k] = r
        return r

    # --- materials ---
    def material(self, k, name=None):
        n = self.N[k]; t = n["type"]
        if t == "BRDFVRayMtl":
            return self.vraymtl(k, name)
        if t == "BRDFLight":
            return self.lightmtl(k, name)
        if t == "BRDFLayered":
            return self.blendmtl(k, name)
        if t == "Mtl2Sided":
            return self.two_sided(k, name)
        WARN.append(f"{self.name} : root {t} not rebuilt"); return None

    def lightmtl(self, k, name=None):
        L = self.N[k]["inputs"]
        m = rt.VRayLightMtl(); m.name = name or f"{self.name}_light"
        mult = float(L.get("Color Multiplier", 1.0))
        lc = L.get("Light Color", [1, 1, 1])
        if isinstance(lc, dict):
            nc = self.N[lc["from"]]
            if nc["type"] == "TexCombineColorLightMtl":                  # texture (plugged, or its colour) x result multiplier
                tx = nc["inputs"].get("Texture"); mult *= float(nc["inputs"].get("Result Multiplier", 1.0))
                if isinstance(tx, dict):
                    x = self.map(tx, "Emission")
                    if x is not None:
                        _set(m, "texmap", x); _set(m, "texmap_on", True); _set(m, "color", rt.Color(255, 255, 255))
                elif tx is not None:
                    lc = tx
            else:
                x = self.map(lc, "Emission")
                if x is not None:
                    _set(m, "texmap", x); _set(m, "texmap_on", True)
        if isinstance(lc, (list, tuple)):
            mx = max(float(c) for c in lc[:3])
            if mx > 1:
                lc = [float(c) / mx for c in lc[:3]]; mult *= mx
            _set(m, "color", _color(lc))
        _set(m, "multiplier", mult)
        _set(m, "twoSided", bool(L.get("Double Sided", False)))
        if L.get("Emit On Back Side"):
            _set_first(m, ("emitOnBackSide", "emit_on_back_side", "backside_emit"), True, "emit on back side")
        _set(m, "compensate_exposure", bool(L.get("Compensate Exposure", False)))
        op = L.get("Opacity", [1, 1, 1])
        if isinstance(op, dict):
            x = self.map(op, "Opacity")
            if x is not None:
                _set(m, "opacity_texmap", x); _set(m, "opacity_texmap_on", True)
        elif min(float(c) for c in op[:3]) < 1:
            v = rt.VRayColor(); _set(v, "color", _color(op)); _set(m, "opacity_texmap", v); _set(m, "opacity_texmap_on", True)
        if L.get("Multiply By Opacity"):
            _set(m, "opacity_multiplyColor", True)
        if L.get("Affect GI") is False:
            WARN.append(f"{m.name} : light with no effect on GI in V-Ray (Affect GI), not carried over")
        return m

    def blendmtl(self, k, name=None):
        B = self.N[k]["inputs"]
        m = rt.VRayBlendMtl(); m.name = name or f"{self.name}_blend"
        b = B.get("Base Material")
        if isinstance(b, dict):
            _set(m, "baseMtl", self.material(b["from"], f"{self.name}_base"))
        i = 1; coats = []
        while f"Coat Material {i}" in B or i == 1:
            c = B.get(f"Coat Material {i}")
            if not isinstance(c, dict):
                if i > 1:
                    break
                i += 1; continue
            w = B.get(f"Blend Amount {i}", [1, 1, 1])
            coats.append((i, self.material(c["from"], f"{self.name}_coat{i}"), w))
            i += 1
        for i, cm, w in coats:
            try:
                m.coatMtl[i - 1] = cm
                if isinstance(w, dict):
                    x = self.map(w, "Blend")
                    if x is not None:
                        m.texmap_blend[i - 1] = x
                else:
                    m.blend[i - 1] = _color(w if isinstance(w, (list, tuple)) else [w, w, w])
            except Exception as e:
                WARN.append(f"{m.name} : coat {i} not set ({e})")
        mode = B.get("Mode", self.N[k]["params"].get("additive_mode"))
        if str(mode) == "1":
            _set(m, "additiveMode", True)
        return m

    def two_sided(self, k, name=None):
        D = self.N[k]["inputs"]
        m = rt.VRay2SidedMtl(); m.name = name or f"{self.name}_2sided"
        f = D.get("Front"); b = D.get("Back")
        if isinstance(f, dict):
            _set(m, "frontMtl", self.material(f["from"], f"{self.name}_front"))
        if isinstance(b, dict):
            _set(m, "backMtl", self.material(b["from"], f"{self.name}_back")); _set(m, "backMtlOn", True)
        tr = D.get("Translucency", [0.5, 0.5, 0.5])
        if isinstance(tr, dict):
            x = self.map(tr, "Translucency")
            if x is not None:
                _set(m, "texmap_translucency", x); _set(m, "texmap_translucency_on", True)
                _set(m, "texmap_translucency_multiplier", 100.0 * float(D.get("Translucency Texture Multiplier", 1.0)))
        else:
            _set(m, "translucency", _color(tr))
        _set_first(m, ("force1SidedSubMtls", "force_1sided"), bool(D.get("Force Single-sided Sub-materials", True)), "single-sided sub-materials")
        if D.get("Multiply By Front Diffuse"):
            _set_first(m, ("mult_by_front_diffuse", "multiplyByFrontDiffuse"), True, "multiply by front diffuse")
        return m

    def vraymtl(self, k=None, name=None):
        k = k or next(x for x, v in self.N.items() if v["type"] == "BRDFVRayMtl")
        b = self.N[k]["inputs"]
        m = rt.VRayMtl(); m.name = name or self.name
        use_r = bool(b.get("Use Roughness"))
        _set(m, "brdf_useRoughness", use_r)
        _set(m, "brdf_type", int(b.get("BRDF Type", 4)))
        _set(m, "option_doubleSided", bool(b.get("Double-sided", True)))

        def slot(key, value_prop, map_prop, conv, channel, mult_prop=None, mult=None):
            v = b.get(key)
            if isinstance(v, dict):
                mp = self.map(v, channel)
                if mp is not None:
                    _set(m, map_prop, mp)
                    if mult_prop:
                        _set(m, mult_prop, mult if mult is not None else 100.0)
                    return
                WARN.append(f"{self.name} / {channel} : map not rebuilt, default value")
            elif v is not None and value_prop:
                _set(m, value_prop, conv(v))

        slot("Diffuse Color", "diffuse", "texmap_diffuse", _color, "BaseColor")
        slot("Reflection Color", "reflection", "texmap_reflection", _color, "Specular")
        slot("Reflection Glossiness", "reflection_glossiness", "texmap_reflectionGlossiness", float, "Roughness")
        _set(m, "reflection_fresnel", bool(b.get("Fresnel Reflections", True)))
        if b.get("Lock Fresnel IOR", True) is False:
            _set(m, "reflection_lockIOR", False)
        _set(m, "reflection_ior", float(b.get("Fresnel IOR", 1.6)))
        slot("Metalness", "reflection_metalness", "texmap_metalness", float, "Metallic")
        slot("Refraction Color", "refraction", "texmap_refraction", _color, "Refraction")
        _set(m, "refraction_ior", float(b.get("Refraction IOR", 1.6)))
        slot("Refraction Glossiness", "refraction_glossiness", "texmap_refractionGlossiness", float, "RefractionGlossiness")
        op = b.get("Opacity")
        if isinstance(op, dict):
            slot("Opacity", None, "texmap_opacity", None, "Opacity")
        elif op is not None and min(op[:3]) < 1:
            mp = rt.VRayColor(); _set(mp, "color", _color(op)); _set(m, "texmap_opacity", mp)
        slot("Self-Illumination Color", "selfIllumination", "texmap_self_illumination", _color, "Emission")
        if b.get("Compensate Camera Exposure"):
            _set_first(m, ("compensate_camera_exposure", "selfIllumination_compensateExposure"), True, "compensate camera exposure")
        fc = b.get("Fog Color")
        if isinstance(fc, dict) or (isinstance(fc, (list, tuple)) and min(float(x) for x in fc[:3]) < 0.999):
            slot("Fog Color", "refraction_fogColor", "texmap_refraction_fog", _color, "Fog")
            fm = float(self.N[k]["params"].get("fog_mult", 1.0))
            _set(m, "refraction_fogMult", fm)
            WARN.append(f"{m.name} : refraction fog (multiplier {fm}, per cm in V-Ray for Blender): check it in a render")
        ca = b.get("Coat Amount", 0)
        if not isinstance(ca, dict) and float(ca) > 0:
            _set(m, "coat_amount", float(ca)); _set(m, "coat_ior", float(b.get("Coat IOR", 1.6)))
            if not isinstance(b.get("Coat Glossiness"), dict):
                _set(m, "coat_glossiness", float(b.get("Coat Glossiness", 1.0)))
            if not isinstance(b.get("Coat Color"), dict):
                _set(m, "coat_color", _color(b.get("Coat Color", [1, 1, 1])))
        sh = b.get("Sheen Color")
        if isinstance(sh, dict) or (isinstance(sh, (list, tuple)) and max(sh[:3]) > 0):
            slot("Sheen Color", "sheen_color", "texmap_sheen", _color, "Sheen")
            slot("Sheen Glossiness", "sheen_glossiness", "texmap_sheenGlossiness", float, "SheenGlossiness")
        if str(b.get("Translucency Type", "0")) != "0":
            _set(m, "translucency_on", int(b.get("Translucency Type")))
            slot("Translucency Color", "translucency_color", "texmap_translucent", _color, "Translucency")
        v = b.get("Bump Map")
        if isinstance(v, dict):
            nb = self.N[v["from"]]
            mp = self.map(v, "Normal")
            if mp is not None:
                k_ = float(nb.get("params", {}).get("bump_tex_mult", 1.0)) if nb["type"] == "TexNormalBump" else 1.0
                k_ *= float(b.get("Bump Amount", 1.0))
                _set(m, "texmap_bump", mp); _set(m, "texmap_bump_multiplier", 100.0 * k_)
        return m


def build(name, g, u):
    c = Builder(name, g, u)
    return c.material(root_node(c.N), name)


# =====================================================================================================
# LIGHTS
# =====================================================================================================

def _m3(rows, u):
    """3ds Max rows (X axis, Y axis, Z axis, position in metres) -> Matrix3 in scene units"""
    a, b, c, d = rows
    return rt.Matrix3(rt.Point3(*a), rt.Point3(*b), rt.Point3(*c), rt.Point3(*(float(x) * u for x in d)))


def make_light(e, u):
    P = e.get("inputs", {}); p = e.get("params", {}); bl = e.get("blender", {})
    pg = e.get("plugin")
    val = lambda key, k, d=None: P.get(key, p.get(k, d)) if not isinstance(P.get(key), dict) else p.get(k, d)
    if pg in ("LightSphere", "LightRectangle"):
        l = rt.VRayLight()
        if pg == "LightSphere":
            _set(l, "type", 2); _set(l, "size0", float(val("Radius", "radius", 0.05)) * u)
            _set_first(l, ("sphere_segments", "sphereSegments"), int(p.get("sphere_segments", 20)), "sphere segments")
        else:
            disc = bool(val("Is Disc", "is_disc", False)) or bl.get("shape") in ("DISK", "ELLIPSE")
            tx, ty = float(bl.get("size", 1.0)), float(bl.get("size_y", bl.get("size", 1.0)))
            if bl.get("shape") in ("SQUARE", "DISK"):
                ty = tx
            _set(l, "type", 4 if disc else 0)
            _set(l, "size0", tx / 2 * u)
            if not disc:
                _set(l, "size1", ty / 2 * u)
            _set(l, "doubleSided", bool(val("DoubleSided", "doubleSided", False)))
            d = float(val("Directional", "directional", 0))
            if d > 0:
                _set_first(l, ("lightDistribution", "directional"), d, "directionality")
            if str(p.get("lightPortal", "0")) != "0":
                _set(l, "skylightPortal", True)
        _set(l, "multiplier", float(val("Intensity", "intensity", 1.0)))
        _set(l, "normalizeColor", int(val("Units", "units", 0)))
        _set(l, "invisible", bool(val("Invisible", "invisible", False)))
        _set(l, "noDecay", bool(p.get("noDecay", False)))
        _set(l, "affect_reflections", bool(val("Affect Reflections", "affectReflections", True)))
        _set(l, "subdivs", int(p.get("subdivs", 8)))
        on = "on"
    elif pg == "LightIES":
        l = rt.VRayIES()
        ies = e.get("ies", {})
        _set(l, "ies_file", ies.get("path", ""))
        if ies and not ies.get("exists"):
            WARN.append(f"{e['name']} : IES file not found {ies.get('path')}")
        _set(l, "power", float(val("Power", "power", 1000)))
        sh = int(val("IES Light Shape", "ies_light_shape", -1))
        if sh >= 0:
            _set_first(l, ("override_shape", "use_shape"), True, "override shape"); _set_first(l, ("shape", "ies_shape"), sh, "shape")
            for props, k in ((("width",), "ies_light_width"), (("length",), "ies_light_length"), (("height",), "ies_light_height"), (("diameter",), "ies_light_diameter")):
                _set_first(l, props, float(p.get(k, 0)) * u, k)
        _set_first(l, ("use_light_shape", "soft_shadows"), int(val("Soft Shadows", "soft_shadows", 1)), "soft shadows (light shape)")
        _set(l, "area_speculars", bool(val("Area Speculars", "area_speculars", True)))
        on = "enabled"
    else:
        WARN.append(f"{e['name']} : light {pg} not created" + (" (LightMesh without geometry)" if pg == "LightMesh" else ""))
        return None, None
    l.name = e["name"]
    c = P.get("Color", p.get("color", [1, 1, 1]))
    if isinstance(c, dict):
        WARN.append(f"{e['name']} : colour from a texture not carried over (white)"); c = [1, 1, 1]
    _set(l, "color", _color(c))
    _set_first(l, ("castShadows", "cast_shadows", "shadows"), bool(val("Shadows", "shadows", True)), "shadows")
    _set_first(l, ("affect_diffuse", "affectDiffuse"), bool(val("Affect Diffuse", "affectDiffuse", True)), "diffuse")
    _set_first(l, ("affect_specular", "affectSpecular"), bool(val("Affect Specular", "affectSpecular", True)), "specular")
    if not bool(val("Enabled", "enabled", True)) or e.get("hidden"):
        _set(l, on, False); l.isHidden = True
    return l, on


def place_lights(L, nodes, u):
    """the file's lights, placed in their parent (same name among `nodes`) or relative to the root"""
    names = {str(d.name): d for d in nodes}
    made, skipped = [], []
    root = names.get(L.get("root"))
    top = None
    for e in L.get("lights") or []:
        par = names.get(e.get("parent")) if e.get("parent") else None
        # already there = same name under the same parent (a second copy of an asset gets its own lights)
        if par is not None:
            there = any(str(c.name) == e["name"] for c in par.children)
        else:
            if top is None:
                top = set(str(o.name) for o in rt.objects if o.parent is None)
            there = e["name"] in top
        if there:
            skipped.append(e["name"]); continue
        try:
            made.append(_one_light(e, L, par, root, u))
        except Exception as ex:
            WARN.append(f"{e.get('name')} : light not created ({ex})")
    made = [m for m in made if m]
    _log(f"Lights created: {len(made)}" + (": " + ", ".join(made) if made else ""))
    if skipped:
        _log("Lights already under their parent (not created again): " + ", ".join(skipped))
    return made


def _one_light(e, L, par, root, u):
    l, on = make_light(e, u)
    if l is None:
        return None
    if par is None and e.get("parent"):
        WARN.append(f"{e['name']} : parent {e['parent']} not found: placed relative to the root")
    with pymxs.attime(int(L.get("frame", 0))):
        if par is not None and e.get("in_parent"):
            l.transform = _m3(e["in_parent"], u) * par.transform
        elif root is not None and e.get("in_root"):
            l.transform = _m3(e["in_root"], u) * root.transform
        else:
            l.transform = _m3(e["world"], u)
        if par is not None:
            l.parent = par
    if e.get("keys"):
        with pymxs.animate(True):
            for f, rows in e["keys"]:
                with pymxs.attime(int(f)):
                    l.transform = _m3(rows, u) * (par.transform if par is not None else rt.Matrix3(1))
    if e.get("animated_parents") and par is None:
        WARN.append(f"{e['name']} : animated parent missing, the light will not follow it")
    return f"{e['name']} [{rt.classOf(l)}]" + (" (off, hidden)" if e.get("hidden") else "") + (f" ({len(e['keys'])} keys)" if e.get("keys") else "")


# =====================================================================================================
# SCENE: what is there, what gets replaced
# =====================================================================================================

def _is_vray(m):
    return str(rt.classOf(m)) in VRAY_MTLS


def _top_and_subs(m):
    """a material and, for a Multi/Sub-Object, its sub-materials"""
    out = [m]
    if rt.classOf(m) == rt.MultiMaterial:
        out += [s for s in m.materialList if s is not None]
    return out


def existing_vray(names):
    """V-Ray materials of the scene (on objects, Multi/Sub included) whose name is in `names`: {name: [materials]}"""
    out = {}
    for o in rt.objects:
        m = o.material
        if m is None:
            continue
        for c in _top_and_subs(m):
            nm = str(c.name)
            if nm in names and _is_vray(c):
                lst = out.setdefault(nm, [])
                if c not in lst:
                    lst.append(c)
    return out


def _h(x):
    return int(rt.getHandleByAnim(x))


def _with_children(nodes):
    acc, seen = [], set()
    for n in nodes:
        for d in _descendants(n, []):
            if _h(d) not in seen:
                seen.add(_h(d)); acc.append(d)
    return acc


def _ms_global(name):
    """a MAXScript global, or None when it is not defined"""
    try:
        v = getattr(rt, name)
    except Exception:
        return None
    return v


def ask_existing(names):
    """dialog of aioli-fbx2vray.ms (Reuse / Rebuild / Cancel), or a Yes / No / Cancel box without it"""
    f = _ms_global("aioli_fbx2vray_ask")
    if f is not None:
        try:
            r = str(f("\n".join(names), len(names))).lower()
            if r in ("reuse", "rebuild", "cancel"):
                return r
        except Exception as e:
            WARN.append(f"question dialog not opened ({e}): Yes / No / Cancel box instead")
    shown = "\n".join(names[:20]) + (f"\n... and {len(names) - 20} more" if len(names) > 20 else "")
    r = str(rt.yesNoCancelBox(f"{len(names)} V-Ray material(s) with the same name already in the scene:\n\n{shown}\n\n"
                              "Yes: reuse them as they are\nNo: rebuild them from the .json, everywhere they are used\n"
                              "Cancel: stop, nothing changes", title=TOOL)).lower().lstrip("#")
    return "reuse" if r == "yes" else "rebuild" if r == "no" else "cancel"


def resolve(G, mode):
    """(mode, existing): mode 'new' when no V-Ray material of the file is in the scene, else reuse / rebuild / cancel"""
    existing = existing_vray(set(G))
    if not existing:
        return "new", existing
    if mode in ("reuse", "rebuild"):
        return mode, existing
    return ask_existing(sorted(existing)), existing


def _users():
    """handles of the materials and maps used by an object of the scene"""
    acc, seen = [], set()
    for o in rt.objects:
        if o.material is not None:
            _maps_of(o.material, acc, seen)
    return seen


def _maps_of(m, acc, seen):
    """a material or map and every map it holds (acc: the objects, seen: their handles)"""
    if m is None or _h(m) in seen:
        return acc
    seen.add(_h(m)); acc.append(m)
    try:
        for i in range(1, int(rt.getNumSubTexmaps(m)) + 1):
            _maps_of(rt.getSubTexmap(m, i), acc, seen)
    except Exception:
        pass
    try:
        for i in range(1, int(rt.getNumSubMtls(m)) + 1):
            _maps_of(rt.getSubMtl(m, i), acc, seen)
    except Exception:
        pass
    return acc


def remove_from_slate(olds):
    """replaced materials: taken out of the Slate views with their maps when nothing in the scene uses them any more
    (phys2vray's method: sme.GetView / GetNodeByRef / SetSelectedNodes / DeleteSelection). A material nothing uses
    is not saved with the scene: once out of the views, it is gone."""
    used = _users()
    dead, dh = [], set()
    for a in olds:
        for x in _maps_of(a, [], set()):
            if _h(x) not in used and _h(x) not in dh:
                dh.add(_h(x)); dead.append(x)
    kept = [str(a.name) for a in olds if _h(a) in used]
    removed = 0
    try:
        nv = int(rt.sme.GetNumViews())
    except Exception:
        nv = 0
    for i in range(1, nv + 1):
        try:
            v = rt.sme.GetView(i)
            for _ in range(5):
                inside = [x for x in dead if v.GetNodeByRef(x) is not None]
                if not inside:
                    break
                v.SelectNone(); v.SetSelectedNodes(inside); v.DeleteSelection(); removed += len(inside)
        except Exception as e:
            WARN.append(f"Slate view {i} not cleaned: {e}")
    return removed, kept


def apply_materials(V, nodes, mode, existing):
    """replace, on `nodes`, every non-V-Ray material named in the file; mode 'new' / 'reuse' / 'rebuild'"""
    G = V["materials"]; u = _units_per_metre()
    made, olds, reused, rebuilt, others, merged = {}, [], [], [], [], []
    count = [0]

    def get(name):
        if name not in made:
            if mode == "reuse" and name in existing:
                made[name] = existing[name][0]; reused.append(name)
            else:
                try:
                    made[name] = build(name, G[name], u)
                except Exception as e:                  # one broken graph does not stop the others
                    WARN.append(f"{name} : not built ({type(e).__name__}: {e}), left as it is"); made[name] = None
        return made[name]

    def swap(m, put):
        nm = str(m.name)
        if _is_vray(m):
            return
        if nm not in G:
            if nm not in others:
                others.append(nm)
            return
        new = get(nm)
        if new is None:
            return
        if m not in olds:
            olds.append(m)
        put(new); count[0] += 1

    multis = []
    for n in nodes:
        m = n.material
        if m is None:
            continue
        if rt.classOf(m) == rt.MultiMaterial:
            if m in multis:
                continue
            multis.append(m)
            for i in range(int(m.numsubs)):
                s = m.materialList[i]
                if s is not None:
                    def put(x, m=m, i=i):
                        m.materialList[i] = x
                    swap(s, put)
        else:
            def put(x, n=n):
                n.material = x
            swap(m, put)

    if mode in ("reuse", "rebuild"):
        # rebuild: the new material everywhere; reuse: the first one everywhere, duplicates of the same name merged
        for nm, lst in sorted(existing.items()):
            new = get(nm)
            if new is None:
                continue
            for o in lst:
                if o != new:
                    rt.replaceInstances(o, new)
                    if o not in olds:
                        olds.append(o)
            if mode == "rebuild":
                rebuilt.append(nm)
            elif len(lst) > 1:
                merged.append(f"{nm} (x{len(lst)})")

    if olds:
        nr, kept = remove_from_slate(olds)
        _log(f"Old materials: {len(olds)} replaced; {nr} node(s) taken out of the Slate views")
        if kept:
            _log("  kept (still used elsewhere): " + ", ".join(kept))
    built = [k for k in sorted(made) if made[k] is not None and k not in reused]
    _log(f"Material slots replaced: {count[0]}")
    _log(f"V-Ray materials built from the file: {len(built)}" + (" (" + ", ".join(f"{k} [{rt.classOf(made[k])}]" for k in built) + ")" if built else ""))
    if reused:
        _log("Reused as they are (already in the scene): " + ", ".join(sorted(reused)))
    if rebuilt:
        _log("Rebuilt from the file, everywhere they were used: " + ", ".join(rebuilt))
    if merged:
        _log("Same name, several V-Ray materials: merged into the first one: " + ", ".join(merged))
    missing = sorted(set(G) - set(made))
    if missing:
        _log("In the file but not on these objects: " + ", ".join(missing))
    if others:
        _log(f"Not in the file, left as they are ({len(others)}): " + ", ".join(sorted(others))
             + " -- phys2vray CONVERT TO V-RAY handles Physical Materials")
    return made


def check_rendering_space(V):
    """colour values of the file are linear in the rendering space of the source scene (ACEScg in ours)"""
    want = str(V.get("rendering_space") or "ACEScg")
    have = None
    try:
        have = str(rt.ColorPipelineMgr.renderingColorSpace)
    except Exception:
        pass
    if have is None:
        _log(f"Colours are set as linear {want} values (rendering space of this scene not read: check it matches).")
    elif want.lower().replace(" ", "") not in have.lower().replace(" ", ""):
        WARN.append(f"colours of the file are {want}, this scene renders in {have}: colours will be off")


# =====================================================================================================
# ACTIONS
# =====================================================================================================

def _fbx_param(name, v):
    try:
        rt.FBXImporterSetParam(name, v)
    except Exception as e:
        WARN.append(f"FBX import: setting {name} not set ({e})")


def import_fbx(fbx):
    """imports the FBX without its dialog; returns the nodes created"""
    before = set(int(rt.getHandleByAnim(o)) for o in rt.objects)
    _fbx_param("Mode", rt.Name("create"))
    _fbx_param("SmoothingGroups", True)
    _fbx_param("Animation", True)
    _fbx_param("Cameras", False)
    _fbx_param("Lights", False)
    # units: the importer's automatic setting (ConvertUnit expects a unit as text, not a boolean: hit in test, 2026-10-27)
    ok = rt.importFile(fbx, rt.Name("noPrompt"), using=rt.FBXIMP)
    if not ok:
        raise RuntimeError(f"import refused: {fbx}")
    return [o for o in rt.objects if int(rt.getHandleByAnim(o)) not in before]


def _open_phys2vray(here):
    """the phys2vray of this clone (read from disk, like its button), else the one in memory"""
    p = os.path.join(os.path.dirname(here.rstrip("\\/")), "phys2vray", "aioli-phys2vray.ms") if here else ""
    if p and os.path.exists(p):
        try:
            rt.fileIn(p); return True
        except Exception as e:
            WARN.append(f"phys2vray not opened from {p} ({e})")
    f = _ms_global("aioli_phys2vray_open")
    if f is not None:
        try:
            f(); return True
        except Exception:
            pass
    return False


def _materials_work(V, nodes, mode, existing, lights):
    check_rendering_space(V)
    with pymxs.undo(True, TOOL):
        apply_materials(V, nodes, mode, existing)
        if lights and V.get("lights"):
            place_lights(V["lights"], nodes, _units_per_metre())
        elif V.get("lights"):
            _log(f"{len(V['lights'].get('lights') or [])} light(s) in the file, not created (option off)")


def run_import(fbx, opts, here=""):
    vj = os.path.splitext(fbx)[0] + "_vray.json"
    V = None
    if os.path.exists(vj):
        try:
            V = read_vray_json(vj)
        except Exception as e:
            _log(f"{os.path.basename(vj)} not read: {e}")
            if not rt.queryBox(f"{os.path.basename(vj)} could not be read:\n{e}\n\nImport the FBX alone (Physical Materials)?", title=TOOL):
                _log("Cancelled: nothing imported."); return
    if V is not None:
        mode, existing = resolve(V["materials"], opts.get("existing", "ask"))
        if mode == "cancel":
            _log("Cancelled: nothing imported."); return
        _log(f"{os.path.basename(vj)}: format {V['_read_as']}, {len(V['materials'])} material(s), "
             f"{len((V.get('lights') or {}).get('lights') or [])} light(s)")
    nodes = import_fbx(fbx)
    _log(f"Imported: {os.path.basename(fbx)}, {len(nodes)} node(s)")
    if nodes:
        rt.select(nodes)
    if V is None:
        _log(f"No {os.path.basename(vj)} next to the FBX: Physical Materials of the FBX kept, the new objects are selected.")
        if _open_phys2vray(here):
            _log("phys2vray is open: CONVERT TO V-RAY makes VRayMtl from them (generic match).")
        else:
            _log("For VRayMtl: phys2vray (aioli-max-scripts), CONVERT TO V-RAY on the selection.")
        return
    _materials_work(V, nodes, mode, existing, opts.get("lights", True))


def run_apply(path, opts):
    V = read_vray_json(path)
    _log(f"{os.path.basename(path)}: format {V['_read_as']}, {len(V['materials'])} material(s), "
         f"{len((V.get('lights') or {}).get('lights') or [])} light(s)")
    sel = list(rt.selection)
    if not sel:
        if not rt.queryBox("Nothing is selected.\n\nApply the .json to every object of the scene?", title=TOOL):
            _log("Cancelled."); return
        sel = list(rt.objects)
    nodes = _with_children(sel)
    mode, existing = resolve(V["materials"], opts.get("existing", "ask"))
    if mode == "cancel":
        _log("Cancelled: nothing changed."); return
    _materials_work(V, nodes, mode, existing, opts.get("lights", True))


# =====================================================================================================
# ENTRY -- the panel (aioli-fbx2vray.ms) sets the MAXScript global aioli_fbx2vray_request, then runs this file
# =====================================================================================================

def _request():
    """'key=value' lines from the panel; defaults when the file is run on its own"""
    opts = {"action": "import", "existing": "ask", "lights": True, "here": ""}      # here: this tool's folder in the clone
    raw = _ms_global("aioli_fbx2vray_request")
    if raw is not None:
        for line in str(raw).splitlines():
            if "=" in line:
                k, v = line.split("=", 1); opts[k.strip()] = v.strip()
    opts["lights"] = str(opts["lights"]).lower() not in ("0", "false", "off")
    if not opts["here"] and "__file__" in globals():
        opts["here"] = os.path.dirname(os.path.abspath(__file__))
    return opts


def _ini():
    try:
        return os.path.join(str(rt.getDir(rt.Name("plugcfg"))), "aioli-fbx2vray.ini")
    except Exception:
        return ""


def _pick(caption, types):
    ini = _ini(); start = ""
    try:
        start = str(rt.getINISetting(ini, "paths", "last_dir")) if ini else ""
    except Exception:
        pass
    f = rt.getOpenFileName(caption=caption, filename=(start.rstrip("\\/") + os.sep) if start else "", types=types)
    if f:
        try:
            rt.setINISetting(ini, "paths", "last_dir", os.path.dirname(str(f)))
        except Exception:
            pass
        return str(f)
    return None


def main():
    del WARN[:]
    opts = _request()
    try:
        if opts["action"] == "apply":
            f = _pick("Apply a _vray.json to the selection", "V-Ray file (*_vray.json)|*_vray.json|JSON (*.json)|*.json")
            if f:
                run_apply(f, opts)
        else:
            f = _pick("Import an FBX (its _vray.json is read if it sits next to it)", "FBX (*.fbx)|*.fbx")
            if f:
                run_import(f, opts, opts.get("here", ""))
    except Exception as e:
        _log(f"stopped: {e}")
        traceback.print_exc()
    finally:
        for a in WARN:
            print("  ! " + a)
        try:
            rt.redrawViews()
        except Exception:
            pass


if __name__ == "__main__" or _ms_global("aioli_fbx2vray_request") is not None:     # Run Script / python.ExecuteFile, or the panel
    main()
