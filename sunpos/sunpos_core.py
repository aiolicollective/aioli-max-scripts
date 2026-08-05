"""
aioli-sunpos - computation core
===============================
Solar position (azimuth / elevation) and conversion into the X / Y / Z
coordinates of a 3ds Max scene.

**Standard library only.** This file is imported unchanged by the CLI
(`aioli_sunpos.py`) and by the 3ds Max tool (`max/aioli_sunpos_max.py`): one
single source of truth for the maths.

Conventions
-----------
* 3ds Max axes: +X = right, +Y = forward (North at rotation 0), +Z = up.
* Azimuth `Az`: from true North, clockwise (N=0, E=90, S=180, W=270).
* Scene rotation `R` (degrees, about world Z):

      X = target.x + D * cos(el) * sin(Az - R)
      Y = target.y + D * cos(el) * cos(Az - R)
      Z = target.z + D * sin(el)

  Sanity check: Az = 0 (true North) must land on (-sin R, cos R).

Accuracy
--------
Solar position uses the *NOAA Solar Calculator* equations (after Meeus),
driven by the Julian day, so the result genuinely depends on the **year**:
~0.01 deg on declination and ~0.1 min on the equation of time.

Elevations are corrected for **atmospheric refraction** by default: light from
the sun bends in the atmosphere, so the direction it actually arrives from is
the *apparent* one, not the geometric one. The correction is negligible high in
the sky (<0.05 deg above 20 deg) but reaches ~0.5 deg at the horizon, where it
can halve a shadow's length. Pass `refraction=False` for purely geometric
positions.

License: MIT - (c) aioli collective
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

# Bumped whenever the public signatures change. The 3ds Max panel checks it, so
# a half-updated folder fails with a clear message instead of a cryptic
# "unexpected keyword argument".
CORE_VERSION = 2

# Validity window of the NOAA / Meeus equations at the stated ~0.01 deg
# accuracy. Outside it the result degrades gracefully (a few arc-minutes per
# century) but is flagged in the notes.
YEAR_MIN, YEAR_MAX = 1800, 2100

__all__ = [
    "CORE_VERSION",
    "YEAR_MIN",
    "YEAR_MAX",
    "HORIZON_DEG",
    "PolarDayNight",
    "SunResult",
    "julian_day",
    "parse_location",
    "looks_like_location",
    "solar_position",
    "refraction_deg",
    "apparent_elevation",
    "noon_elevation",
    "sun_events",
    "distance_for_zmax",
    "direction_to_xyz",
    "compute_sun",
    "sun_path",
]

# Official sunrise / sunset threshold: atmospheric refraction (~0.57 deg) plus
# the sun's apparent radius (~0.27 deg). A *geometric* elevation between this
# threshold and 0 means "sun sitting on the horizon".
HORIZON_DEG = -0.833


class PolarDayNight(RuntimeError):
    """Raised when there is no sunrise or sunset (polar day or polar night)."""

    def __init__(self, kind: str):
        self.kind = kind          # "day" or "night"
        super().__init__(
            "Polar day: the sun does not set on this date."
            if kind == "day" else
            "Polar night: the sun does not rise on this date."
        )


# ========================================================================== #
#  1. Reading a GPS point
# ========================================================================== #
_C = r"(-?\d+(?:\.\d+)?)"

_LOCATION_PATTERNS = (
    rf"\A\s*{_C}\s*[,;]\s*{_C}\s*\Z",                     # "lat,lng"
    rf"!3d{_C}!4d{_C}",                                    # Google Maps pin
    rf"@{_C},{_C}",                                        # camera / street view
    rf"[?&](?:q|ll|query|sll|daddr|center)={_C},{_C}",     # ?q=lat,lng
)


def looks_like_location(text: str) -> bool:
    """True if `text` looks like a GPS point or a map link."""
    try:
        parse_location(text)
        return True
    except ValueError:
        return False


def parse_location(text: str) -> tuple[float, float]:
    """(latitude, longitude) from "lat,lng" or a Google Maps link.

    Raises ValueError if nothing is recognisable, or if the values fall outside
    the valid ranges (lat +-90, lon +-180).
    """
    s = str(text).strip().strip("\"'")
    for rx in _LOCATION_PATTERNS:
        m = re.search(rx, s)
        if m:
            lat, lon = float(m.group(1)), float(m.group(2))
            if not -90.0 <= lat <= 90.0:
                raise ValueError(f"Latitude out of range: {lat} (expected -90..90)")
            if not -180.0 <= lon <= 180.0:
                raise ValueError(f"Longitude out of range: {lon} (expected -180..180)")
            return lat, lon
    raise ValueError(f"Could not read coordinates from: {text!r}")


# ========================================================================== #
#  2. Solar position (NOAA Solar Calculator)
# ========================================================================== #
def julian_day(dt_utc: datetime) -> float:
    """Julian day (with fractional part) of a UTC datetime.

    Meeus' formula, Gregorian calendar. This is what makes the computation
    genuinely **year-dependent**: the sun's position on a given calendar date
    drifts from year to year (the tropical year is 365.2422 days, caught up in
    jumps by leap years).
    """
    dt = dt_utc.astimezone(timezone.utc)
    y, m = dt.year, dt.month
    day = dt.day + (dt.hour + dt.minute / 60
                    + (dt.second + dt.microsecond / 1e6) / 3600) / 24
    if m <= 2:
        y -= 1
        m += 12
    a = y // 100
    b = 2 - a + a // 4
    return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + day + b - 1524.5


def _solar_terms(dt_utc: datetime) -> tuple[float, float]:
    """(declination_rad, equation_of_time_min) for a UTC datetime.

    *NOAA Solar Calculator* equations (after Meeus, "Astronomical Algorithms").
    Accuracy ~0.01 deg on declination and ~0.1 min on the equation of time
    between 1800 and 2100.
    """
    t = (julian_day(dt_utc) - 2451545.0) / 36525.0        # Julian centuries

    l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360.0   # mean longitude
    m = 357.52911 + t * (35999.05029 - 0.0001537 * t)              # mean anomaly
    e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)         # eccentricity
    mr = math.radians(m)

    # equation of the centre -> true longitude
    c = (math.sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
         + math.sin(2 * mr) * (0.019993 - 0.000101 * t)
         + math.sin(3 * mr) * 0.000289)

    omega = math.radians(125.04 - 1934.136 * t)           # nutation
    app_long = math.radians(l0 + c - 0.00569 - 0.00478 * math.sin(omega))

    eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
    eps = math.radians(eps0 + 0.00256 * math.cos(omega))  # corrected obliquity

    decl = math.asin(math.sin(eps) * math.sin(app_long))

    yy = math.tan(eps / 2) ** 2
    l0r = math.radians(l0)
    eqtime = 4 * math.degrees(
        yy * math.sin(2 * l0r)
        - 2 * e * math.sin(mr)
        + 4 * e * yy * math.sin(mr) * math.cos(2 * l0r)
        - 0.5 * yy * yy * math.sin(4 * l0r)
        - 1.25 * e * e * math.sin(2 * mr))
    return decl, eqtime


def _require_aware(dt: datetime, what: str = "datetime") -> datetime:
    if dt.tzinfo is None or dt.tzinfo.utcoffset(dt) is None:
        raise ValueError(f"{what} must carry a time zone (timezone-aware).")
    return dt


def solar_position(lat_deg: float, lon_deg: float,
                   dt_aware: datetime) -> tuple[float, float]:
    """(azimuth deg from true North clockwise, **geometric** elevation deg).

    Correct in both hemispheres. `dt_aware` must be timezone-aware.
    Apply `apparent_elevation()` to obtain the refracted elevation.
    """
    _require_aware(dt_aware)
    dt_utc = dt_aware.astimezone(timezone.utc)
    decl, eqtime = _solar_terms(dt_utc)

    lat = math.radians(lat_deg)
    utc_min = dt_utc.hour * 60 + dt_utc.minute + dt_utc.second / 60
    tst = utc_min + eqtime + 4 * lon_deg          # true solar time (minutes)
    ha = math.radians(tst / 4 - 180)              # hour angle (+ = afternoon)

    sin_el = (math.sin(lat) * math.sin(decl)
              + math.cos(lat) * math.cos(decl) * math.cos(ha))
    el = math.asin(max(-1.0, min(1.0, sin_el)))

    # East / North components of the sun vector (ENU frame)
    east = -math.cos(decl) * math.sin(ha)
    north = (math.cos(lat) * math.sin(decl)
             - math.sin(lat) * math.cos(decl) * math.cos(ha))
    az = math.degrees(math.atan2(east, north)) % 360.0
    return az, math.degrees(el)


# ========================================================================== #
#  3. Atmospheric refraction
# ========================================================================== #
def refraction_deg(el_deg: float) -> float:
    """Atmospheric refraction in degrees, to be ADDED to a geometric elevation.

    NOAA piecewise approximation, for standard conditions (1013.25 hPa, 10 C).
    Roughly 0.57 deg at the horizon, 0.03 deg at 45 deg, 0 at the zenith.

    Real conditions (temperature, pressure, inversion layers) shift this by a
    few tenths of a degree near the horizon, and no model can predict that for
    a future date. This is the accuracy floor at sunrise / sunset.
    """
    if el_deg > 85.0:
        return 0.0
    te = math.tan(math.radians(el_deg))
    if el_deg > 5.0:
        arcsec = 58.1 / te - 0.07 / te ** 3 + 0.000086 / te ** 5
    elif el_deg > -0.575:
        arcsec = 1735.0 + el_deg * (-518.2 + el_deg * (
            103.4 + el_deg * (-12.79 + el_deg * 0.711)))
    else:
        arcsec = -20.772 / te
    return arcsec / 3600.0


def apparent_elevation(el_deg: float) -> float:
    """Geometric elevation -> apparent (refracted) elevation, in degrees."""
    return el_deg + refraction_deg(el_deg)


def _utc_noon_ref(lat_deg: float, lon_deg: float, date_local: datetime):
    """UTC reference for solar noon on the LOCAL date of `date_local`.

    We start from UTC midnight of the *local civil date* rather than converting
    12:00 local to UTC, which jumps a day for zones beyond +12 h or below -12 h.
    The declination is then evaluated at approximate solar noon, so it always
    lands on the right day.
    """
    utc_ref = datetime(date_local.year, date_local.month, date_local.day,
                       tzinfo=timezone.utc)
    approx_noon = utc_ref + timedelta(minutes=720 - 4 * lon_deg)
    decl, eqtime = _solar_terms(approx_noon)
    noon_utc = utc_ref + timedelta(minutes=720 - eqtime - 4 * lon_deg)
    return decl, eqtime, noon_utc


def noon_elevation(lat_deg: float, lon_deg: float, date_local: datetime,
                   refraction: bool = True) -> float:
    """Highest elevation of the day (solar-noon culmination), in degrees.

    May be negative (polar night).
    """
    decl, _, _ = _utc_noon_ref(lat_deg, lon_deg, date_local)
    el = 90.0 - abs(lat_deg - math.degrees(decl))
    return apparent_elevation(el) if refraction else el


def sun_events(lat_deg: float, lon_deg: float, date_local: datetime) -> dict:
    """{'sunrise', 'noon', 'sunset', 'day_length_h'} for the local date.

    Values are aware datetimes in `date_local`'s time zone. Raises
    PolarDayNight if the sun never rises or never sets.
    """
    _require_aware(date_local, "date_local")
    tz = date_local.tzinfo
    decl, _eqtime, noon_utc = _utc_noon_ref(lat_deg, lon_deg, date_local)

    lat = math.radians(lat_deg)
    denom = math.cos(lat) * math.cos(decl)
    if abs(denom) < 1e-12:                       # exactly at a pole
        raise PolarDayNight("day" if decl * lat_deg > 0 else "night")

    cos_h0 = (math.sin(math.radians(HORIZON_DEG))
              - math.sin(lat) * math.sin(decl)) / denom
    if cos_h0 <= -1.0:
        raise PolarDayNight("day")
    if cos_h0 >= 1.0:
        raise PolarDayNight("night")

    h0_min = math.degrees(math.acos(cos_h0)) * 4      # half-day length, minutes
    return {
        "sunrise": (noon_utc - timedelta(minutes=h0_min)).astimezone(tz),
        "noon": noon_utc.astimezone(tz),
        "sunset": (noon_utc + timedelta(minutes=h0_min)).astimezone(tz),
        "day_length_h": 2 * h0_min / 60.0,
    }


# ========================================================================== #
#  4. Direction -> scene XYZ
# ========================================================================== #
def distance_for_zmax(lat_deg: float, lon_deg: float, date_local: datetime,
                      z_max_cm: float,
                      refraction: bool = True) -> tuple[float, str]:
    """(distance_cm, note).

    The distance is chosen so that the day's culmination lands exactly at
    `z_max_cm` above the reference point: the whole day's path then stays under
    the ceiling with a single distance. Since a physical sun emits *parallel*
    rays, this distance has no effect on the render - only the direction does.
    """
    el_noon = noon_elevation(lat_deg, lon_deg, date_local, refraction=refraction)
    peak = math.sin(math.radians(el_noon))
    if peak <= 1e-4:                     # polar night, or grazing sun
        return float(z_max_cm), (
            f"Day's culmination is {el_noon:.2f} deg: distance fell back to "
            f"z_max ({z_max_cm:g} cm). No usable direct sunlight."
        )
    return z_max_cm / peak, ""


def direction_to_xyz(az_deg: float, el_deg: float, north_rot_deg: float,
                     distance_cm: float,
                     target=(0.0, 0.0, 0.0)) -> tuple[float, float, float]:
    """Direction (az / el) + scene rotation -> absolute XYZ."""
    az = math.radians(az_deg - north_rot_deg)
    el = math.radians(el_deg)
    return (target[0] + distance_cm * math.cos(el) * math.sin(az),
            target[1] + distance_cm * math.cos(el) * math.cos(az),
            target[2] + distance_cm * math.sin(el))


# ========================================================================== #
#  5. Result
# ========================================================================== #
@dataclass
class SunResult:
    latitude: float
    longitude: float
    local_time: str
    utc_offset_h: float
    timezone_label: str
    azimuth_deg: float
    elevation_deg: float                 # the one actually used for placement
    geometric_elevation_deg: float       # before refraction
    refraction_deg: float
    north_rotation_deg: float
    distance_cm: float
    X_cm: float
    Y_cm: float
    Z_cm: float
    horizon: str                         # "above" | "on" | "below"
    note: str = ""

    @property
    def above_horizon(self) -> bool:
        return self.horizon == "above"

    @property
    def horizon_label(self) -> str:
        return {"above": "", "on": " (on the horizon)",
                "below": " (below the horizon)"}[self.horizon]

    def as_row(self) -> str:
        return (f"{self.local_time}  az={self.azimuth_deg:7.2f}  "
                f"el={self.elevation_deg:7.2f}  "
                f"X={self.X_cm:11.1f}  Y={self.Y_cm:11.1f}  Z={self.Z_cm:11.1f}")

    def as_dict(self) -> dict:
        d = dict(self.__dict__)
        d["above_horizon"] = self.above_horizon
        return d


def _horizon_state(el_deg: float) -> str:
    """Classify an *apparent* elevation. At the computed sunrise the apparent
    elevation is about -0.44 deg (centre below, upper limb touching), hence the
    tolerance band."""
    if el_deg > 0.0:
        return "above"
    if el_deg >= -0.6:
        return "on"
    return "below"


def _tz_label(dt_aware: datetime) -> str:
    tz = dt_aware.tzinfo
    key = getattr(tz, "key", None)
    off = dt_aware.utcoffset() or timedelta(0)
    stamp = f"UTC{off.total_seconds() / 3600.0:+g}"
    if key:
        name = dt_aware.tzname()
        return f"{key} ({name}, {stamp})" if name else f"{key} ({stamp})"
    return stamp


def _dst_warning(dt_naive: datetime, tz) -> str:
    """Detect a local time that does not exist, or that happens twice."""
    try:
        a = dt_naive.replace(tzinfo=tz, fold=0)
        b = dt_naive.replace(tzinfo=tz, fold=1)
        if a.utcoffset() != b.utcoffset():
            return ("Ambiguous local time (daylight-saving change): the first "
                    "occurrence was used. Pass an explicit UTC offset if in doubt.")
        # non-existent time: the UTC round trip does not return what was typed
        if a.astimezone(timezone.utc).astimezone(tz).replace(tzinfo=None) != dt_naive:
            return ("This local time does not exist on that date (clocks jumped "
                    "forward). The time zone shifted the computation.")
    except Exception:
        pass
    return ""


# ========================================================================== #
#  6. Main API
# ========================================================================== #
def compute_sun(location, dt_naive: datetime, tz, north_rotation_deg: float = 0.0,
                target=(0.0, 0.0, 0.0), z_max_cm: float = 1500.0,
                distance_cm: float | None = None,
                refraction: bool = True) -> SunResult:
    """Sun position for a local wall-clock time.

    Parameters
    ----------
    location : "lat,lng", a Google Maps link, or a (lat, lon) tuple
    dt_naive : NAIVE datetime = wall-clock time on site
    tz       : tzinfo (ZoneInfo, or timezone(timedelta(...))) - see
               `aioli_sunpos.resolve_timezone` / `sunpos_zones.zone_offset`
    refraction : apply the atmospheric refraction correction (default True)
    """
    lat, lon = (parse_location(location)
                if isinstance(location, str) else
                (float(location[0]), float(location[1])))
    if dt_naive.tzinfo is not None:
        raise ValueError("dt_naive must be naive (local wall-clock time, no "
                         "time zone): the time zone is supplied separately.")

    warn = _dst_warning(dt_naive, tz)
    dt_aware = dt_naive.replace(tzinfo=tz)
    az, el_geom = solar_position(lat, lon, dt_aware)

    refr = refraction_deg(el_geom) if refraction else 0.0
    el = el_geom + refr

    note_parts = [p for p in (warn,) if p]
    if not YEAR_MIN <= dt_naive.year <= YEAR_MAX:
        note_parts.append(
            f"Year {dt_naive.year} is outside the {YEAR_MIN}-{YEAR_MAX} window "
            f"where the NOAA equations hold to ~0.01 deg. The result is still "
            f"usable but degrades by a few arc-minutes per century.")
    if distance_cm is None:
        distance_cm, dnote = distance_for_zmax(lat, lon, dt_aware, z_max_cm,
                                               refraction=refraction)
        if dnote:
            note_parts.append(dnote)

    x, y, z = direction_to_xyz(az, el, north_rotation_deg, distance_cm, target)
    state = _horizon_state(el)
    if state == "below":
        note_parts.append("Sun below the horizon (night): no direct sunlight.")
    elif state == "on":
        note_parts.append("Sun on the horizon (sunrise / sunset): Z is near 0.")

    return SunResult(
        latitude=round(lat, 6), longitude=round(lon, 6),
        local_time=dt_aware.strftime("%Y-%m-%d %H:%M"),
        utc_offset_h=round((dt_aware.utcoffset() or timedelta(0)).total_seconds() / 3600, 4),
        timezone_label=_tz_label(dt_aware),
        azimuth_deg=round(az, 2), elevation_deg=round(el, 2),
        geometric_elevation_deg=round(el_geom, 2), refraction_deg=round(refr, 3),
        north_rotation_deg=float(north_rotation_deg),
        distance_cm=round(distance_cm, 1),
        X_cm=round(x, 1), Y_cm=round(y, 1), Z_cm=round(z, 1),
        horizon=state, note="  ".join(note_parts),
    )


def sun_path(location, date_naive: datetime, tz, step_hours: float = 2.0,
             north_rotation_deg: float = 0.0, target=(0.0, 0.0, 0.0),
             z_max_cm: float = 1500.0,
             refraction: bool = True) -> list[SunResult]:
    """Sun path from sunrise to sunset, one sample every `step_hours`.

    Sunrise and sunset are always included, and **all** samples share the same
    distance (the day's culmination pinned at z_max).
    """
    lat, lon = (parse_location(location)
                if isinstance(location, str) else
                (float(location[0]), float(location[1])))
    if step_hours <= 0:
        raise ValueError("step_hours must be > 0.")

    ref = date_naive.replace(hour=12, minute=0, second=0,
                             microsecond=0, tzinfo=tz)
    ev = sun_events(lat, lon, ref)                # raises PolarDayNight
    dist, dnote = distance_for_zmax(lat, lon, ref, z_max_cm,
                                    refraction=refraction)

    stamps: list[datetime] = []
    t, end = ev["sunrise"], ev["sunset"]
    while t < end:
        stamps.append(t)
        t += timedelta(hours=step_hours)
    stamps.append(end)                            # exact sunset

    out = []
    for ts in stamps:
        res = compute_sun((lat, lon), ts.replace(tzinfo=None), tz,
                          north_rotation_deg=north_rotation_deg,
                          target=target, distance_cm=dist,
                          refraction=refraction)
        if dnote and dnote not in res.note:
            res.note = (res.note + "  " + dnote).strip()
        out.append(res)
    return out
