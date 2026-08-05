#!/usr/bin/env python3
"""
sunpos - time-zone resolution
=============================
Two jobs, one file:

1. `resolve_timezone(...)` - the single place where a time zone is decided,
   used by both the CLI and (indirectly) the 3ds Max panel.
2. A command-line entry point printing JSON, so the Max panel can ask the
   question without importing anything heavy:

       python tzlookup.py <lat> <lon> <YYYY-MM-DD> <HH:MM>
       -> {"ok": true, "tz": "Australia/Sydney", "abbrev": "AEST", "utc_offset_h": 10.0}
       -> {"ok": false, "error": "..."}                      (exit code 1)

**Why the subprocess dance.** Turning GPS coordinates into an IANA zone needs
`timezonefinder`, and reading that zone needs `tzdata` - on Windows `zoneinfo`
ships with NO time-zone database at all. Installing either into Autodesk's
Python risks breaking other pipeline tools. So the Max panel runs THIS file with
the project's `.venv` interpreter (the one `setup.bat` builds) and parses one
line of JSON. Max's own Python stays 100 % standard library.

`sunpos_max.py` depends on this module only through that subprocess call, and
`sunpos_cli.py` imports `resolve_timezone` from here - so the CLI can be deleted
without breaking the Max tool.

License: MIT - (c) aioli collective
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sunpos_zones import zone_offset, zone_warning              # noqa: E402

# ---- optional dependencies, only needed for GPS -> zone ------------------- #
try:
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
    _HAVE_ZONEINFO = True
except Exception:                                         # pragma: no cover
    _HAVE_ZONEINFO = False

    class ZoneInfoNotFoundError(Exception):
        pass

try:
    from timezonefinder import TimezoneFinder
    _TF = TimezoneFinder()
except Exception:                                         # pragma: no cover
    _TF = None


INSTALL_HINT = (
    "Could not determine the time zone automatically.\n"
    "  -> run `setup.bat` (Windows) or `./setup.sh` to install\n"
    "     timezonefinder + tzdata into the project's .venv,\n"
    "  -> or name the zone yourself: --zone Europe/Paris  (offline table)\n"
    "  -> or force an offset:        --utc-offset 2"
)


def resolve_timezone(lat: float, lon: float, tz_name: str | None = None,
                     utc_offset: float | None = None,
                     zone: str | None = None,
                     naive_local: datetime | None = None,
                     on_warning=None):
    """(tzinfo, source_label).

    Priority: utc_offset > zone > tz_name > automatic (GPS via timezonefinder).
    Daylight saving is NEVER guessed: it comes from the IANA database, from the
    published rule of an explicitly named zone, or from an explicit offset.

    `on_warning` is called with a string when the answer is usable but should be
    treated with caution (currently: a date predating a zone's current DST rule).
    """
    if utc_offset is not None:
        off = float(utc_offset)
        return timezone(timedelta(hours=off)), "manual UTC%+g" % off

    if zone:
        when = naive_local or datetime.now()
        tz, off, abbr, dst = zone_offset(zone, when)
        warn = zone_warning(zone, when)
        if warn and on_warning:
            on_warning(warn)
        return tz, "%s (%s, UTC%+g, %s, offline table)" % (
            zone, abbr, off, "DST" if dst else "standard")

    if tz_name:
        if not _HAVE_ZONEINFO:
            raise RuntimeError("Python without `zoneinfo` (3.9+ required).")
        try:
            return ZoneInfo(tz_name), "IANA %s" % tz_name
        except ZoneInfoNotFoundError:
            raise RuntimeError(
                f"Unknown IANA zone: {tz_name!r}, or tzdata is missing.\n"
                "  -> run setup.bat / ./setup.sh (installs tzdata), or use "
                "--zone (offline table)."
            ) from None

    if _TF is not None and _HAVE_ZONEINFO:
        name = _TF.timezone_at(lat=lat, lng=lon)
        if name:
            try:
                return ZoneInfo(name), "auto from GPS: %s" % name
            except ZoneInfoNotFoundError:
                raise RuntimeError(
                    f"Zone {name} found from GPS but tzdata is missing.\n"
                    "  -> run setup.bat / ./setup.sh."
                ) from None
        raise RuntimeError(
            f"No IANA zone for {lat}, {lon} (open ocean?). Use --zone or "
            "--utc-offset.")
    raise RuntimeError(INSTALL_HINT)


# ========================================================================== #
#  JSON entry point (called by sunpos_max.py through the .venv)
# ========================================================================== #
def main(argv):
    if len(argv) != 4:
        print(json.dumps({"ok": False, "error":
                          "usage: tzlookup.py <lat> <lon> <YYYY-MM-DD> <HH:MM>"}))
        return 2
    try:
        lat, lon = float(argv[0]), float(argv[1])
        y, mo, d = (int(v) for v in argv[2].split("-"))
        hh, mm = (int(v) for v in argv[3].replace("h", ":").split(":")[:2])
    except Exception as exc:
        print(json.dumps({"ok": False, "error": "invalid arguments: %s" % exc}))
        return 2

    try:
        tz, _src = resolve_timezone(lat, lon)
        aware = datetime(y, mo, d, hh, mm, tzinfo=tz)
        print(json.dumps({
            "ok": True,
            "tz": getattr(tz, "key", str(tz)),
            "abbrev": aware.tzname() or "",
            "utc_offset_h": aware.utcoffset().total_seconds() / 3600.0,
        }))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
