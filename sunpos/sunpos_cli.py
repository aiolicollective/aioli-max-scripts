#!/usr/bin/env python3
"""
sunpos - command line (usage outside 3ds Max)
===========================
Computes the X / Y / Z position (cm) to type into a 3ds Max sun (VRay Sun,
Corona Sun, directional light...) so that it matches the real sun of a place,
on a given date and time.

    python sunpos_cli.py "48.840006, 2.276764" "2026-09-29 19:30" --north 121
    python sunpos_cli.py "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2
    python sunpos_cli.py "48.84, 2.27" 2026-09-29 --path 1 --json > day.json

On Windows use `run.bat` instead (or `run.sh` elsewhere): it creates and uses a
local `.venv` without ever touching the system Python.

License: MIT - (c) aioli collective
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sunpos_core import (                                        # noqa: E402
    PolarDayNight, SunResult, compute_sun, looks_like_location,
    parse_location, sun_events, sun_path,
)
from sunpos_zones import ZONES, ZoneError, zone_keys              # noqa: E402
from tzlookup import resolve_timezone                            # noqa: E402


# ========================================================================== #
#  Output
# ========================================================================== #
def _fmt_single(res: SunResult, ev: dict | None, polar: str | None,
                tz_src: str) -> str:
    w = 54
    lines = [
        "",
        "  sunpos",
        "  " + "-" * w,
        f"  Location   : {res.latitude}, {res.longitude}",
        f"  Time zone  : {tz_src}",
        f"  Local time : {res.local_time}",
        f"  Sun        : azimuth {res.azimuth_deg:.2f} deg   "
        f"elevation {res.elevation_deg:.2f} deg{res.horizon_label}",
    ]
    if res.refraction_deg:
        lines.append(
            f"               (geometric {res.geometric_elevation_deg:.2f} deg "
            f"+ {res.refraction_deg:.3f} deg refraction)")
    if ev:
        lines.append(
            f"  Day        : sunrise {ev['sunrise']:%H:%M}   "
            f"noon {ev['noon']:%H:%M}   sunset {ev['sunset']:%H:%M}   "
            f"({ev['day_length_h']:.2f} h)")
    elif polar:
        lines.append(f"  Day        : {polar}")
    lines += [
        f"  North rot. : {res.north_rotation_deg:g} deg      "
        f"distance {res.distance_cm:g} cm",
        "  " + "-" * w,
        f"  X = {res.X_cm:>13.1f} cm",
        f"  Y = {res.Y_cm:>13.1f} cm",
        f"  Z = {res.Z_cm:>13.1f} cm",
    ]
    if res.note:
        lines += [""] + [f"  ! {p.strip()}" for p in res.note.split("  ") if p.strip()]
    lines.append("")
    return "\n".join(lines)


def _fmt_path(rows: list[SunResult], step: float, ev: dict, tz_src: str) -> str:
    w = 84
    head = [
        "",
        f"  sunpos - sun path, one sample every {step:g} h",
        f"  {rows[0].latitude}, {rows[0].longitude}   {tz_src}",
        f"  sunrise {ev['sunrise']:%H:%M}   noon {ev['noon']:%H:%M}   "
        f"sunset {ev['sunset']:%H:%M}   ({ev['day_length_h']:.2f} h)",
        f"  north rotation {rows[0].north_rotation_deg:g} deg   "
        f"shared distance {rows[0].distance_cm:g} cm",
        "  " + "-" * w,
    ]
    body = ["  " + r.as_row() + r.horizon_label for r in rows]
    return "\n".join(head + body + ["  " + "-" * w, ""])


# ========================================================================== #
#  Arguments
# ========================================================================== #
_SENTINEL = "\x00loc:"


def _protect_location(argv: list[str]) -> list[str]:
    """Stop argparse from reading a negative latitude as an option.

    "-33.86,151.21" starts with '-', which argparse rejects. We prefix tokens
    that *look like* a location, and strip the prefix after parsing. Welcome
    side effect: options may then appear anywhere on the command line.
    """
    return [_SENTINEL + tok if tok.startswith("-") and looks_like_location(tok)
            else tok for tok in argv]


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sunpos",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Sun position (X, Y, Z in cm) for a 3ds Max scene.",
        epilog=(
            "examples:\n"
            '  sunpos_cli.py "48.840006, 2.276764" "2026-09-29 19:30" --north 121\n'
            '  sunpos_cli.py "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2\n'
            '  sunpos_cli.py "48.84, 2.27" 2026-06-21 --zone Europe/Paris\n'
            "  sunpos_cli.py --list-zones\n"
        ))
    p.add_argument("location", nargs="?",
                   help='GPS point "lat,lng" or a Google Maps link')
    p.add_argument("datetime", metavar="DATETIME", nargs="?",
                   help='local time "YYYY-MM-DD HH:MM" '
                        "(date alone is enough with --path)")
    p.add_argument("--north", type=float, default=0.0, metavar="DEG",
                   help="world-Z rotation of the scene's north axis, deg (default 0)")
    p.add_argument("--target", default="0,0,0", metavar="X,Y,Z",
                   help="reference point / sun target, cm (default 0,0,0)")
    p.add_argument("--zmax", type=float, default=1500.0, metavar="CM",
                   help="max Z height above the reference point, cm (default 1500)")
    p.add_argument("--distance", type=float, default=None, metavar="CM",
                   help="force a fixed distance, ignoring --zmax")
    p.add_argument("--path", type=float, default=None, metavar="STEP_H",
                   help="sun path from sunrise to sunset, one sample every "
                        "STEP_H hours")
    p.add_argument("--zone", default=None, metavar="IANA",
                   help="named zone from the offline table (nothing to install), "
                        "e.g. Europe/Paris - see --list-zones")
    p.add_argument("--tz", default=None, metavar="IANA",
                   help="IANA zone via tzdata, e.g. Europe/Paris")
    p.add_argument("--utc-offset", type=float, default=None, metavar="H",
                   help="force a UTC offset in hours (overrides --zone / --tz)")
    p.add_argument("--no-refraction", action="store_true",
                   help="report purely geometric elevations, without the "
                        "atmospheric refraction correction")
    p.add_argument("--list-zones", action="store_true",
                   help="list the zones available to --zone, then exit")
    p.add_argument("--json", action="store_true",
                   help="JSON output instead of the readable table")
    return p


def _parse_target(text: str) -> tuple[float, float, float]:
    parts = [v.strip() for v in text.replace(";", ",").split(",")]
    if len(parts) != 3:
        raise ValueError(f"--target expects 'x,y,z' (got {text!r})")
    try:
        return tuple(float(v) for v in parts)          # type: ignore[return-value]
    except ValueError:
        raise ValueError(f"--target: non-numeric values in {text!r}") from None


def _parse_dt(text: str, path_mode: bool) -> datetime:
    s = text.strip().replace("T", " ")
    if path_mode:
        return datetime.strptime(s.split()[0], "%Y-%m-%d")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d %Hh%M"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    raise ValueError(
        f"Unreadable date/time: {text!r}. Expected \"YYYY-MM-DD HH:MM\" "
        '(or just "YYYY-MM-DD" with --path).')


def _print_zones() -> int:
    print("\n  Zones available to --zone (offline table, nothing to install):\n")
    for key in zone_keys():
        std, _rule, std_abbr, dst_abbr, label = ZONES[key]
        dst = f"/{dst_abbr}" if dst_abbr else ""
        print(f"    {key:<34} UTC{std:+g}  {std_abbr}{dst:<6}  {label}")
    print("\n  Daylight saving comes from each zone's published rule, applied to")
    print("  the date you give. For a contractual date prefer the IANA database")
    print("  (--tz, or the automatic GPS lookup): it is always current.\n")
    return 0


# ========================================================================== #
#  main
# ========================================================================== #
def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    parser = _build_parser()
    args = parser.parse_args(_protect_location(raw))

    if args.list_zones:
        return _print_zones()
    if not args.location or not args.datetime:
        parser.error("the following arguments are required: location, DATETIME")
    if args.location.startswith(_SENTINEL):
        args.location = args.location[len(_SENTINEL):]

    refraction = not args.no_refraction
    try:
        lat, lon = parse_location(args.location)
        target = _parse_target(args.target)
        dt = _parse_dt(args.datetime, args.path is not None)
        tz, tz_src = resolve_timezone(
            lat, lon, args.tz, args.utc_offset, args.zone, dt,
            on_warning=lambda w: print("\n  ! %s\n" % w, file=sys.stderr))
    except (ValueError, RuntimeError, ZoneError) as exc:
        print(f"\n  Error: {exc}\n", file=sys.stderr)
        return 2

    # ---- sun path -------------------------------------------------------- #
    if args.path is not None:
        try:
            rows = sun_path((lat, lon), dt, tz, step_hours=args.path,
                            north_rotation_deg=args.north, target=target,
                            z_max_cm=args.zmax, refraction=refraction)
            ev = sun_events(lat, lon, dt.replace(hour=12, tzinfo=tz))
        except (PolarDayNight, ValueError) as exc:
            print(f"\n  Error: {exc}\n", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps({
                "location": {"lat": lat, "lon": lon},
                "timezone": tz_src,
                "refraction": refraction,
                "sunrise": ev["sunrise"].isoformat(),
                "noon": ev["noon"].isoformat(),
                "sunset": ev["sunset"].isoformat(),
                "day_length_h": round(ev["day_length_h"], 4),
                "north_rotation_deg": args.north,
                "target_cm": list(target),
                "distance_cm": rows[0].distance_cm,
                "samples": [r.as_dict() for r in rows],
            }, indent=2, ensure_ascii=False))
        else:
            print(_fmt_path(rows, args.path, ev, tz_src))
        return 0

    # ---- single position ------------------------------------------------- #
    try:
        res = compute_sun((lat, lon), dt, tz, north_rotation_deg=args.north,
                          target=target, z_max_cm=args.zmax,
                          distance_cm=args.distance, refraction=refraction)
    except ValueError as exc:
        print(f"\n  Error: {exc}\n", file=sys.stderr)
        return 2

    ev, polar = None, None
    try:
        ev = sun_events(lat, lon, dt.replace(hour=12, minute=0, second=0,
                                             microsecond=0, tzinfo=tz))
    except PolarDayNight as exc:
        polar = str(exc)

    if args.json:
        payload = res.as_dict()
        payload["target_cm"] = list(target)
        payload["timezone_source"] = tz_src
        payload["refraction"] = refraction
        if ev:
            payload.update(sunrise=ev["sunrise"].isoformat(),
                           noon=ev["noon"].isoformat(),
                           sunset=ev["sunset"].isoformat(),
                           day_length_h=round(ev["day_length_h"], 4))
        elif polar:
            payload["polar"] = polar
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(_fmt_single(res, ev, polar, tz_src))
    return 0


if __name__ == "__main__":
    sys.exit(main())
