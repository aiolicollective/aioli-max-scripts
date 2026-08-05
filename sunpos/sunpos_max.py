"""
sunpos - 3ds Max tool
===========================
Pick any sun already present in the scene (VRay Sun, Corona Sun, native target
light, free directional...) and place it so it matches the REAL sun of a given
location / date / time, taking the scene's north rotation into account.

Behaviour
---------
* You PICK an existing sun: the tool never creates one.
* If the sun has a target, its position is read as the reference point. The
  target is NEVER moved, only the sun's position is.
* If the sun has no target (free directional), you type a reference point and
  the tool also AIMS the node at it - moving a free light alone would not
  change the direction of its light.
* On every "Place sun" the previous position animation is cleared first, so
  switching between `single` and `path` leaves no stale keys behind.
* The scene's system units are read and the cm you type are converted.

Time zone (daylight saving is never guessed):
* `zone`   - pick a named zone from an offline table. Nothing to install; DST
             comes from that zone's published rule, applied to your date.
* `manual` - raw UTC offset.
* `auto`   - resolved from GPS via the IANA database. Nothing is installed into
             3ds Max: the tool delegates that one question to the project's
             `.venv` (built by setup.bat) through `tzlookup.py`.

To launch: drag `max/aioli-sunpos.ms` into a 3ds Max window, then use the
toolbar button (category "aioli"). Or Scripting > Run Script... on this file.

License: MIT - (c) aioli collective
"""

import importlib
import json
import os
import subprocess
import sys
import traceback
from datetime import datetime, timedelta, timezone

REQUIRED_CORE_VERSION = 2

# --------------------------------------------------------------------------- #
#  Import the computation core shared with the CLI (pure stdlib, no deps)
# --------------------------------------------------------------------------- #
_ROOT = os.path.dirname(os.path.abspath(__file__))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

# 3ds Max keeps ONE Python session alive for the whole application. Modules
# already imported stay cached in `sys.modules`, so `python.ExecuteFile` re-runs
# this file but silently reuses the *old* sunpos_core - and you get baffling
# "unexpected keyword argument" errors after editing the core, until Max is
# restarted. Force a reload so a click on the toolbar button always picks up
# what is on disk.
#
# Only inside Max, though: reloading swaps the class objects, so any *other*
# module that already did `from sunpos_core import PolarDayNight` would keep a
# stale reference and its `except` clauses would stop matching. Here we re-import
# every name immediately below, so we are safe; the test-suite process is not.
try:
    importlib.import_module("pymxs")
    _HOST_IS_MAX = True
except Exception:
    _HOST_IS_MAX = False

if _HOST_IS_MAX:
    for _name in ("sunpos_core", "sunpos_zones"):
        if _name in sys.modules:
            try:
                importlib.reload(sys.modules[_name])
            except Exception:
                del sys.modules[_name]

try:
    import sunpos_core
    from sunpos_core import (
        PolarDayNight, compute_sun, parse_location, sun_path,
    )
    from sunpos_zones import (
        DEFAULT_ZONE, ZoneError, zone_keys, zone_offset, zone_warning,
    )
except ImportError:                                          # pragma: no cover
    raise ImportError(
        "sunpos_core.py / sunpos_zones.py not found. Keep this file in the "
        "same folder as the rest of the tool. Looked in: %s" % _ROOT
    )

_core_version = getattr(sunpos_core, "CORE_VERSION", 0)
if _core_version != REQUIRED_CORE_VERSION:                   # pragma: no cover
    raise ImportError(
        "Version mismatch: this panel needs sunpos_core v%d but loaded v%d "
        "(from %s).\nMake sure the whole sunpos folder was updated "
        "together, then restart 3ds Max."
        % (REQUIRED_CORE_VERSION, _core_version,
           getattr(sunpos_core, "__file__", "?")))


# Panel defaults. `zone` mode works with nothing installed and still handles
# daylight saving, so it is the sensible default; Paris because that is where
# this was written.
DEFAULT_TZ_MODE = "zone"
DEFAULT_UTC_OFFSET = 2.0


def venv_python():
    """Path to the project's .venv interpreter, or None if it does not exist."""
    for rel in (os.path.join(".venv", "Scripts", "python.exe"),
                os.path.join(".venv", "bin", "python")):
        p = os.path.join(_ROOT, rel)
        if os.path.isfile(p):
            return p
    return None


_NO_VENV = (
    "'auto' mode unavailable: the project's .venv does not exist yet.\n"
    "  -> run setup.bat once, at the root of the sunpos folder\n"
    "     (%s)\n"
    "     It installs nothing into 3ds Max nor into your system Python:\n"
    "     everything stays inside the project's .venv\\ subfolder.\n"
    "  -> or use 'zone' mode, which needs no installation at all."
)

_TZ_CACHE = {}


def resolve_tz(tz_mode, utc_offset, zone, lat, lon, y, mo, d, hh, mm):
    """(tzinfo, source_label). Raises RuntimeError if `auto` fails.

    `auto` mode: resolving GPS -> IANA zone -> offset (daylight saving
    included) needs `timezonefinder` and `tzdata`, and on Windows `zoneinfo`
    has no time-zone database without `tzdata`. Rather than install those into
    Autodesk's Python, we delegate that one question to the project's `.venv`
    via `tzlookup.py`. The result is a fixed offset for the requested instant;
    in `path` mode it is computed at noon, so it stays constant across the
    whole day (no daylight-saving jump mid-path).
    """
    naive = datetime(y, mo, d, hh, mm)

    if tz_mode == "manual":
        off = float(utc_offset)
        return timezone(timedelta(hours=off)), "manual UTC%+g" % off

    if tz_mode == "zone":
        key = zone or DEFAULT_ZONE
        tz, off, abbr, dst = zone_offset(key, naive)
        label = "%s (%s, UTC%+g, %s, offline table)" % (
            key, abbr, off, "DST" if dst else "standard")
        warn = zone_warning(key, naive)
        if warn:
            label += "\n  ! " + warn
        return tz, label

    key = (round(lat, 5), round(lon, 5), y, mo, d, hh, mm)
    if key in _TZ_CACHE:
        return _TZ_CACHE[key]

    py = venv_python()
    if py is None:
        raise RuntimeError(_NO_VENV % _ROOT)

    cmd = [py, os.path.join(_ROOT, "tzlookup.py"), str(lat), str(lon),
           "%04d-%02d-%02d" % (y, mo, d), "%02d:%02d" % (hh, mm)]
    kwargs = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                  cwd=_ROOT, universal_newlines=True, timeout=30)
    if hasattr(subprocess, "CREATE_NO_WINDOW"):        # no console flash
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        proc = subprocess.run(cmd, **kwargs)
    except subprocess.TimeoutExpired:
        raise RuntimeError(
            "The .venv did not answer within 30 s. Use 'zone' mode.") from None
    except OSError as exc:
        raise RuntimeError("Could not launch %s: %s" % (py, exc)) from None

    try:
        data = json.loads((proc.stdout or "").strip().splitlines()[-1])
    except Exception:
        raise RuntimeError(
            "Unreadable answer from the .venv.\n  stdout: %s\n  stderr: %s"
            % ((proc.stdout or "").strip()[:300],
               (proc.stderr or "").strip()[:300])) from None

    if not data.get("ok"):
        raise RuntimeError(
            "%s\n  -> re-run setup.bat, or use 'zone' mode."
            % data.get("error", "unknown failure"))

    off = float(data["utc_offset_h"])
    out = (timezone(timedelta(hours=off)),
           "auto from GPS: %s (%s, UTC%+g)"
           % (data["tz"], data.get("abbrev") or "?", off))
    _TZ_CACHE[key] = out
    return out


# --------------------------------------------------------------------------- #
#  Sample builder
# --------------------------------------------------------------------------- #
def build_samples(lat, lon, date_str, time_str, north, zmax, target,
                  tz_mode=DEFAULT_TZ_MODE, utc_offset=DEFAULT_UTC_OFFSET,
                  zone=DEFAULT_ZONE, mode="single", step_h=2.0,
                  refraction=True):
    """(list of sample dicts, time-zone source label).

    `target` and `zmax` are in centimetres; unit conversion is the caller's job
    (see `SunPosDialog._scale`).
    """
    try:
        y, mo, d = (int(v) for v in date_str.strip().split("-"))
    except Exception:
        raise ValueError("Invalid date: expected YYYY-MM-DD (got %r)" % date_str)
    if mode == "single":
        try:
            parts = time_str.strip().replace("h", ":").split(":")
            hh, mm = int(parts[0]), int(parts[1] or 0)
        except Exception:
            raise ValueError("Invalid time: expected HH:MM (got %r)" % time_str)
    else:
        hh, mm = 12, 0

    tz, src = resolve_tz(tz_mode, utc_offset, zone, lat, lon, y, mo, d, hh, mm)

    if mode == "single":
        rows = [compute_sun((lat, lon), datetime(y, mo, d, hh, mm), tz,
                            north_rotation_deg=north, target=target,
                            z_max_cm=zmax, refraction=refraction)]
    else:
        rows = sun_path((lat, lon), datetime(y, mo, d), tz, step_hours=step_h,
                        north_rotation_deg=north, target=target,
                        z_max_cm=zmax, refraction=refraction)

    out = [dict(label=r.local_time[-5:], x=r.X_cm, y=r.Y_cm, z=r.Z_cm,
                az=r.azimuth_deg, el=r.elevation_deg, horizon=r.horizon,
                note=r.note, dist=r.distance_cm)
           for r in rows]
    return out, src


# --------------------------------------------------------------------------- #
#  Qt + Max UI (only defined when running inside 3ds Max)
# --------------------------------------------------------------------------- #
try:
    from PySide6 import QtWidgets, QtCore
    import pymxs
    _IN_MAX = True
except Exception:
    try:
        from PySide2 import QtWidgets, QtCore          # 3ds Max <= 2024
        import pymxs
        _IN_MAX = True
    except Exception:
        _IN_MAX = False


if _IN_MAX:
    rt = pymxs.runtime

    # Marker set on a node when THIS tool animated it, so we can clear our own
    # keys without ever destroying somebody else's animation unasked.
    _TAG = "aioli_sunpos"

    # cm -> scene system units
    _CM_PER_UNIT = {
        "inches": 2.54, "feet": 30.48, "miles": 160934.4,
        "millimeters": 0.1, "centimeters": 1.0, "meters": 100.0,
        "kilometers": 100000.0,
    }

    def _scene_cm_per_unit():
        """(cm_per_unit, name). 1.0 if the units cannot be identified."""
        try:
            name = str(rt.units.SystemType).lstrip("#").strip("()").lower()
            return _CM_PER_UNIT.get(name, 1.0), name
        except Exception:
            return 1.0, "?"

    def _p3(x, y, z):
        return rt.Point3(float(x), float(y), float(z))

    def _undo_ctx(label):
        """pymxs.undo, tolerant of signature differences between versions."""
        try:
            return pymxs.undo(True, label)
        except TypeError:
            return pymxs.undo(True)

    def _spin(mini, maxi, val, dec=1, step=1.0):
        s = QtWidgets.QDoubleSpinBox()
        s.setRange(mini, maxi)
        s.setDecimals(dec)
        s.setSingleStep(step)
        s.setValue(val)
        s.setKeyboardTracking(False)
        return s

    def _button(text):
        """A QPushButton that does NOT fire on the Enter key.

        Inside a QDialog, Qt sets `autoDefault` on push buttons: pressing Enter
        after typing in a field triggers the first one. That used to be
        'Pick sun', so confirming a value from the keyboard silently switched
        Max into pick mode.
        """
        b = QtWidgets.QPushButton(text)
        b.setAutoDefault(False)
        b.setDefault(False)
        return b

    class SunPosDialog(QtWidgets.QDialog):
        SETTINGS = ("aioli", "sunpos")

        def __init__(self, parent=None):
            super(SunPosDialog, self).__init__(parent)
            self.setWindowTitle("aioli-sunpos")
            self.setMinimumWidth(480)
            self.node = None
            self._cm_per_unit, self._unit_name = _scene_cm_per_unit()

            form = QtWidgets.QFormLayout()
            self.ed_loc = QtWidgets.QLineEdit()
            self.ed_loc.setPlaceholderText("lat,lng  or a Google Maps link")
            form.addRow("Location (GPS / link)", self.ed_loc)

            self.ed_date = QtWidgets.QLineEdit(
                datetime.now().strftime("%Y-%m-%d"))
            self.ed_time = QtWidgets.QLineEdit("12:00")
            form.addRow("Date (YYYY-MM-DD)", self.ed_date)
            form.addRow("Local time (HH:MM)", self.ed_time)

            self.sp_north = _spin(-360, 360, 0.0, 2, 1.0)
            self.sp_zmax = _spin(1, 1e7, 1500.0, 0, 100.0)
            form.addRow("North rotation (deg)", self.sp_north)
            form.addRow("Z max above reference (cm)", self.sp_zmax)

            self.cb_tz = QtWidgets.QComboBox()
            self.cb_tz.addItems(["zone", "manual", "auto"])
            self.cb_zone = QtWidgets.QComboBox()
            self.cb_zone.addItems(zone_keys())
            self.sp_utc = _spin(-14, 14, DEFAULT_UTC_OFFSET, 2, 1.0)
            self.sp_utc.setToolTip(
                "Raw UTC offset. Paris is +1 in winter (CET) and +2 in summer "
                "(CEST).\nUse 'zone' mode to stop thinking about it.")
            self.cb_zone.setToolTip(
                "Daylight saving comes from this zone's published rule, applied "
                "to the date above.\nNothing to install. For a contractual "
                "date prefer 'auto' (IANA database, always current).")
            form.addRow("Time zone mode", self.cb_tz)
            form.addRow("Zone", self.cb_zone)
            form.addRow("UTC offset (manual)", self.sp_utc)

            self.cb_mode = QtWidgets.QComboBox()
            self.cb_mode.addItems(["single", "path (animate the picked sun)"])
            self.sp_step = _spin(0.25, 12, 2.0, 2, 0.5)
            self.sp_frame = _spin(1, 1000, 10, 0, 1.0)
            form.addRow("Mode", self.cb_mode)
            form.addRow("Path step (hours)", self.sp_step)
            form.addRow("Frames per step", self.sp_frame)

            self.chk_refr = QtWidgets.QCheckBox(
                "Correct for atmospheric refraction")
            self.chk_refr.setChecked(True)
            self.chk_refr.setToolTip(
                "Light bends in the atmosphere, so the sun appears higher than "
                "it geometrically is.\nNegligible high in the sky (<0.05 deg "
                "above 20 deg), but ~0.5 deg at the horizon,\nwhere it can "
                "halve a shadow's length. Leave it on for physical accuracy.")
            form.addRow("", self.chk_refr)

            self.ref_group = QtWidgets.QGroupBox(
                "Reference point (suns without a target) - cm")
            rl = QtWidgets.QHBoxLayout(self.ref_group)
            self.sp_rx = _spin(-1e7, 1e7, 0.0, 1, 10.0)
            self.sp_ry = _spin(-1e7, 1e7, 0.0, 1, 10.0)
            self.sp_rz = _spin(-1e7, 1e7, 0.0, 1, 10.0)
            for lab, sp in (("X", self.sp_rx), ("Y", self.sp_ry),
                            ("Z", self.sp_rz)):
                rl.addWidget(QtWidgets.QLabel(lab))
                rl.addWidget(sp)
            self.ref_group.setEnabled(False)

            self.btn_pick = _button("Pick sun")
            self.lbl_pick = QtWidgets.QLabel("No sun picked yet.")
            self.lbl_pick.setWordWrap(True)
            self.btn_apply = _button("Place sun")
            self.btn_apply.setEnabled(False)

            self.out = QtWidgets.QPlainTextEdit()
            self.out.setReadOnly(True)
            self.out.setMinimumHeight(130)
            self.out.setLineWrapMode(QtWidgets.QPlainTextEdit.NoWrap)

            root = QtWidgets.QVBoxLayout(self)
            root.addLayout(form)
            root.addWidget(self.ref_group)
            root.addWidget(self.btn_pick)
            root.addWidget(self.lbl_pick)
            root.addWidget(self.btn_apply)
            root.addWidget(QtWidgets.QLabel("Log:"))
            root.addWidget(self.out)

            self.cb_tz.currentTextChanged.connect(self._sync_tz)
            self.cb_mode.currentTextChanged.connect(self._sync_mode)
            self.btn_pick.clicked.connect(self.on_pick)
            self.btn_apply.clicked.connect(self.run)

            self._load_settings()
            self._sync_tz(self.cb_tz.currentText())
            self._sync_mode(self.cb_mode.currentText())
            if venv_python():
                self.log("[time zone] 'auto' mode ready (project .venv found).")
            else:
                self.log("[time zone] 'auto' unavailable (no .venv). 'zone' mode "
                         "needs no install; run setup.bat in %s for 'auto'." % _ROOT)
            if abs(self._cm_per_unit - 1.0) > 1e-9:
                self.log("[units] scene in %s: the cm you type are converted "
                         "(1 unit = %g cm)." % (self._unit_name, self._cm_per_unit))
            elif self._unit_name != "centimeters":
                self.log("[units] system units '%s' not recognised: no conversion "
                         "applied, values are used as-is." % self._unit_name)

        # ---- settings persistence ----------------------------------------- #
        def _load_settings(self):
            s = QtCore.QSettings(*self.SETTINGS)
            self.ed_loc.setText(s.value("loc", "", str))
            self.sp_north.setValue(float(s.value("north", 0.0)))
            self.sp_zmax.setValue(float(s.value("zmax", 1500.0)))
            self.sp_utc.setValue(float(s.value("utc", DEFAULT_UTC_OFFSET)))
            self.sp_step.setValue(float(s.value("step", 2.0)))
            self.sp_frame.setValue(float(s.value("frames", 10)))
            self.chk_refr.setChecked(s.value("refraction", "1", str) != "0")
            for combo, key, default in ((self.cb_tz, "tzmode", DEFAULT_TZ_MODE),
                                        (self.cb_zone, "zone", DEFAULT_ZONE)):
                i = combo.findText(s.value(key, default, str))
                if i >= 0:
                    combo.setCurrentIndex(i)

        def _save_settings(self):
            s = QtCore.QSettings(*self.SETTINGS)
            s.setValue("loc", self.ed_loc.text())
            s.setValue("north", self.sp_north.value())
            s.setValue("zmax", self.sp_zmax.value())
            s.setValue("utc", self.sp_utc.value())
            s.setValue("step", self.sp_step.value())
            s.setValue("frames", self.sp_frame.value())
            s.setValue("tzmode", self.cb_tz.currentText())
            s.setValue("zone", self.cb_zone.currentText())
            s.setValue("refraction", "1" if self.chk_refr.isChecked() else "0")

        def closeEvent(self, event):
            self._save_settings()
            super(SunPosDialog, self).closeEvent(event)

        def keyPressEvent(self, event):
            """Enter commits the current field and nothing else.

            Otherwise QDialog reads Enter as "accept the dialog": it either
            fires the default button ('Pick sun') or calls accept() and closes
            the panel. Both are surprises when you were just typing a latitude.
            Escape still closes, as everywhere.
            """
            if event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
                event.accept()
                return
            super(SunPosDialog, self).keyPressEvent(event)

        # ---- helpers ------------------------------------------------------ #
        def log(self, msg):
            self.out.appendPlainText(str(msg))

        def _sync_tz(self, mode):
            self.sp_utc.setEnabled(mode == "manual")
            self.cb_zone.setEnabled(mode == "zone")

        def _sync_mode(self, txt):
            path = not txt.startswith("single")
            self.sp_step.setEnabled(path)
            self.sp_frame.setEnabled(path)
            self.ed_time.setEnabled(not path)

        def _target_of(self, node):
            try:
                tgt = getattr(node, "target", None)
            except Exception:
                return None
            try:
                if tgt is not None and tgt != rt.undefined and rt.isValidNode(tgt):
                    return tgt
            except Exception:
                pass
            return None

        # ---- pick --------------------------------------------------------- #
        def on_pick(self):
            node = None
            for attempt in (lambda: rt.pickObject(prompt="Pick a sun / light"),
                            lambda: rt.pickObject()):
                try:
                    node = attempt()
                    break
                except Exception:
                    continue
            if node is None or node == rt.undefined:
                sel = list(rt.selection)
                node = sel[0] if sel else None
            if node is None or node == rt.undefined:
                self.log("Nothing picked.")
                return

            self.node = node
            kind = str(rt.classOf(node))
            tgt = self._target_of(node)
            if tgt is not None:
                p = tgt.pos
                self.lbl_pick.setText(
                    "Picked: %s  [%s]\nTarget @ (%.1f, %.1f, %.1f) units - kept "
                    "as is; only the sun's position will move."
                    % (node.name, kind, p.x, p.y, p.z))
                self.ref_group.setEnabled(False)
            else:
                self.lbl_pick.setText(
                    "Picked: %s  [%s]\nNo target - the reference point below is "
                    "used, and the node will also be AIMED at it."
                    % (node.name, kind))
                self.ref_group.setEnabled(True)
            self.btn_apply.setEnabled(True)

        # ---- compute ------------------------------------------------------ #
        def _reference_cm(self):
            """(target_in_cm, target_in_units, has_target)."""
            tgt = self._target_of(self.node)
            k = self._cm_per_unit
            if tgt is not None:
                p = tgt.pos
                return (p.x * k, p.y * k, p.z * k), (p.x, p.y, p.z), True
            cm = (self.sp_rx.value(), self.sp_ry.value(), self.sp_rz.value())
            return cm, tuple(v / k for v in cm), False

        def run(self):
            """Compute, log, then place. The log is written BEFORE the scene is
            touched: if a number or the resolved zone looks wrong, everything is
            in a single Ctrl+Z."""
            if self.node is None:
                self.log("Pick a sun first.")
                return
            try:
                if not rt.isValidNode(self.node):
                    self.log("The picked node no longer exists. Pick again.")
                    self.node = None
                    self.btn_apply.setEnabled(False)
                    return
            except Exception:
                pass

            try:
                lat, lon = parse_location(self.ed_loc.text())
            except Exception as exc:
                self.log("Location: %s" % exc)
                return

            target_cm, _target_u, has_target = self._reference_cm()
            mode = "single" if self.cb_mode.currentText().startswith("single") \
                else "path"
            try:
                samples, src = build_samples(
                    lat, lon, self.ed_date.text(), self.ed_time.text(),
                    self.sp_north.value(), self.sp_zmax.value(), target_cm,
                    tz_mode=self.cb_tz.currentText(),
                    utc_offset=self.sp_utc.value(),
                    zone=self.cb_zone.currentText(),
                    mode=mode, step_h=self.sp_step.value(),
                    refraction=self.chk_refr.isChecked())
            except (PolarDayNight, ZoneError) as exc:
                self.log("%s" % exc)
                return
            except Exception as exc:
                self.log("Compute: %s" % exc)
                return

            k = self._cm_per_unit
            self.log("-" * 62)
            self.log("[time zone] %s" % src)
            self.log("[reference] (%.1f, %.1f, %.1f) cm   [%d sample(s)]"
                     % (target_cm[0], target_cm[1], target_cm[2], len(samples)))
            for s in (samples[:1] if mode == "single" else samples):
                flag = {"above": "", "on": "  (on the horizon)",
                        "below": "  (below the horizon)"}[s["horizon"]]
                self.log("  %s  az=%7.2f el=%7.2f  ->  (%.1f, %.1f, %.1f)%s"
                         % (s["label"], s["az"], s["el"],
                            s["x"] / k, s["y"] / k, s["z"] / k, flag))
            notes = {n for s in samples for n in s["note"].split("  ") if n.strip()}
            for n in sorted(notes):
                self.log("  ! %s" % n)

            self._save_settings()
            try:
                self._apply(samples, target_cm, has_target, mode)
            except Exception:
                self.log("Max error:\n%s" % traceback.format_exc())

        # ---- existing animation ------------------------------------------- #
        def _position_is_animated(self, node):
            """True if the node's position carries keys. Several probes: the API
            varies with the Max version and the controller type."""
            for probe in (lambda: bool(node.position.isAnimated),
                          lambda: int(rt.numKeys(node.position.controller)) > 0):
                try:
                    return probe()
                except Exception:
                    continue
            return False

        def _we_animated_it(self, node):
            try:
                return rt.getUserProp(node, _TAG) == "animated"
            except Exception:
                return False

        def _mark_animated(self, node, animated):
            try:
                rt.setUserProp(node, _TAG, "animated" if animated else "")
            except Exception:
                pass

        def _clear_position_animation(self, node):
            """Swap in a fresh Position_XYZ controller: all position animation
            goes at once, whatever the original controller was."""
            try:
                node.position.controller = rt.Position_XYZ()
                return True
            except Exception:
                self.log("  ! could not reset the position controller:\n%s"
                         % traceback.format_exc())
                return False

        def _reset_previous(self, node, mode):
            """Clear the previous position animation before replacing it.

            Without this, going from `path` back to `single` left the keys in
            place: the sun looked correctly placed, then moved again as soon as
            you scrubbed the timeline. And re-running a `path` with a different
            step mixed old and new keys. Returns False if the user cancels.
            """
            if not self._position_is_animated(node):
                return True

            if not self._we_animated_it(node):
                btn = QtWidgets.QMessageBox.question(
                    self, "aioli-sunpos",
                    "'%s' already carries a position animation that did not "
                    "come from this tool.\n\nDelete it to place the sun?\n\n"
                    "(undoable with Ctrl+Z)" % node.name,
                    QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
                    QtWidgets.QMessageBox.No)
                if btn != QtWidgets.QMessageBox.Yes:
                    self.log("Cancelled: the existing animation was kept.")
                    return False

            if self._clear_position_animation(node):
                self.log("  previous position animation cleared%s."
                         % ("" if mode == "path" else " (single mode: static sun)"))
            return True

        # ---- apply --------------------------------------------------------- #
        def _apply(self, samples, target_cm, has_target, mode):
            k = self._cm_per_unit
            aim = None if has_target else _p3(target_cm[0] / k,
                                              target_cm[1] / k,
                                              target_cm[2] / k)

            def place(s):
                self.node.pos = _p3(s["x"] / k, s["y"] / k, s["z"] / k)
                if aim is not None:
                    # free light: moving it is not enough, it must be aimed.
                    try:
                        self.node.dir = rt.normalize(aim - self.node.pos)
                    except Exception:
                        pass

            with _undo_ctx("aioli-sunpos"):
                if not self._reset_previous(self.node, mode):
                    return
                if mode == "single":
                    place(samples[0])
                    self._mark_animated(self.node, False)
                    self.log("Placed '%s'  (static, no keys)." % self.node.name)
                else:
                    fs = int(self.sp_frame.value())
                    last = fs * (len(samples) - 1)
                    try:
                        cur = rt.animationRange
                        if cur.end < last:
                            rt.animationRange = rt.interval(cur.start, last)
                            self.log("animationRange extended to %d." % last)
                    except Exception:
                        pass
                    with pymxs.animate(True):
                        for i, s in enumerate(samples):
                            with pymxs.attime(i * fs):
                                place(s)
                    self._mark_animated(self.node, True)
                    self.log("Keyframed '%s': %d samples, one every %d frames "
                             "(0 -> %d)."
                             % (self.node.name, len(samples), fs, last))
            rt.redrawViews()

    _DLG = None

    def launch():
        """Open the panel (single instance)."""
        global _DLG
        try:
            import qtmax
            parent = qtmax.GetQMaxMainWindow()
        except Exception:
            parent = None
        if _DLG is not None:
            try:
                _DLG.close()
                _DLG.deleteLater()
            except Exception:
                pass
        _DLG = SunPosDialog(parent)
        _DLG.show()
        return _DLG


# --------------------------------------------------------------------------- #
#  Entry point
# --------------------------------------------------------------------------- #
if __name__ == "__main__":
    if _IN_MAX:
        launch()
    else:
        print("Outside 3ds Max - self-test (Sydney, 2026-11-21):")
        rows, src = build_samples(
            -33.85991629775957, 151.209074939153, "2026-11-21", "11:41",
            5.0, 1500.0, (0, 0, 0), tz_mode="zone", zone="Australia/Sydney",
            mode="path", step_h=3.0)
        print("  time zone:", src)
        for s in rows:
            print("  %s  az=%7.2f el=%7.2f  X=%9.1f Y=%9.1f Z=%9.1f  %s"
                  % (s["label"], s["az"], s["el"], s["x"], s["y"], s["z"],
                     s["horizon"]))
