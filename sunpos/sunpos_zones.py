"""
aioli-sunpos - offline time-zone table
======================================
UTC offsets for a curated list of IANA zones, **including daylight saving**,
computed from the published transition rules. Standard library only: no
`tzdata`, no `timezonefinder`, nothing to install.

Why this exists
---------------
Resolving a zone from GPS coordinates needs polygon data (~40 MB) plus the IANA
database, and on Windows `zoneinfo` has no time-zone database at all without the
`tzdata` package. That is what `auto` mode delegates to the project's `.venv`.
This module is the middle ground: **you pick the zone explicitly**, and we apply
its legislated DST rule for the date you entered. No install, and no guessing
which zone a point belongs to.

Scope and honesty
-----------------
* The DST rules below are *legislated* rules, not guesses. They have been stable
  for years (EU since 2002, US since 2007, AU/NZ since 2008).
* Every entry is checked against `tzdata` by `tests/test_sunpos.py`, on 24 dates
  spread over the year. Zones whose rule a frozen table cannot honestly track
  are **deliberately absent** rather than approximated:
      - Africa/Cairo      DST reintroduced in 2023, may change again
      - Africa/Casablanca DST suspended during Ramadan, which shifts every year
      - Asia/Jerusalem    its own rule, revised more than once
  For those, use `auto`.
* This is still a **frozen snapshot**. Countries change their rules, and the EU
  has repeatedly debated abolishing DST. If a rule changes, this table goes
  stale silently.
* Historical dates before the current rule took effect will be wrong.

So: use this for everyday work, and use `auto` (IANA `tzdata`, always current)
when a date is contractual or a client is watching. `ZONES` deliberately stays
short and readable -- it is meant to be audited, not to replace tzdata.

License: MIT - (c) aioli collective
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

__all__ = ["ZONES", "zone_keys", "zone_offset", "zone_warning", "describe",
           "DEFAULT_ZONE", "ZoneError", "RULE_SINCE"]

DEFAULT_ZONE = "Europe/Paris"


class ZoneError(KeyError):
    """Raised for an unknown zone key."""


# --------------------------------------------------------------------------- #
#  DST rules
# --------------------------------------------------------------------------- #
NONE = "none"     # no daylight saving
EU = "eu"         # last Sun Mar 01:00 UTC  -> last Sun Oct 01:00 UTC
US = "us"         # 2nd Sun Mar 02:00 local -> 1st Sun Nov 02:00 local
AU = "au"         # 1st Sun Oct 02:00 local -> 1st Sun Apr 02:00 local (southern)
NZ = "nz"         # last Sun Sep 02:00 local -> 1st Sun Apr 02:00 local (southern)

# Year each rule took its current form. Before that, this table is simply wrong
# (the US moved its dates in 2007, Australia and New Zealand in 2007-2008), so
# `zone_warning()` says so instead of quietly returning a plausible number.
RULE_SINCE = {NONE: 0, EU: 2002, US: 2007, AU: 2008, NZ: 2007}

#  key                        std   rule   std    dst    label
ZONES: dict[str, tuple] = {
    # ---- Europe ----------------------------------------------------------- #
    "Europe/Paris":          (1.0,  EU,   "CET",  "CEST", "Paris, Brussels, Madrid, Rome"),
    "Europe/London":         (0.0,  EU,   "GMT",  "BST",  "London, Dublin, Lisbon"),
    "Europe/Berlin":         (1.0,  EU,   "CET",  "CEST", "Berlin, Vienna, Zurich, Oslo"),
    "Europe/Athens":         (2.0,  EU,   "EET",  "EEST", "Athens, Helsinki, Bucharest"),
    "Europe/Moscow":         (3.0,  NONE, "MSK",  "",     "Moscow (no DST since 2011)"),
    "Atlantic/Reykjavik":    (0.0,  NONE, "GMT",  "",     "Reykjavik (no DST)"),
    # ---- Americas --------------------------------------------------------- #
    "America/New_York":      (-5.0, US,   "EST",  "EDT",  "New York, Toronto, Miami"),
    "America/Chicago":       (-6.0, US,   "CST",  "CDT",  "Chicago, Mexico City*, Winnipeg"),
    "America/Denver":        (-7.0, US,   "MST",  "MDT",  "Denver, Calgary"),
    "America/Phoenix":       (-7.0, NONE, "MST",  "",     "Phoenix (no DST)"),
    "America/Los_Angeles":   (-8.0, US,   "PST",  "PDT",  "Los Angeles, Vancouver, Seattle"),
    "America/Anchorage":     (-9.0, US,   "AKST", "AKDT", "Anchorage"),
    "Pacific/Honolulu":      (-10.0, NONE, "HST", "",     "Honolulu (no DST)"),
    "America/Sao_Paulo":     (-3.0, NONE, "-03",  "",     "Sao Paulo (no DST since 2019)"),
    "America/Bogota":        (-5.0, NONE, "-05",  "",     "Bogota, Lima, Panama"),
    "America/Argentina/Buenos_Aires": (-3.0, NONE, "-03", "", "Buenos Aires (no DST)"),
    # ---- Africa / Middle East --------------------------------------------- #
    "Africa/Lagos":          (1.0,  NONE, "WAT",  "",     "Lagos, Algiers, Kinshasa"),
    "Africa/Johannesburg":   (2.0,  NONE, "SAST", "",     "Johannesburg (no DST)"),
    "Africa/Nairobi":        (3.0,  NONE, "EAT",  "",     "Nairobi, Addis Ababa"),
    "Asia/Dubai":            (4.0,  NONE, "+04",  "",     "Dubai, Abu Dhabi, Muscat"),
    # ---- Asia ------------------------------------------------------------- #
    "Asia/Karachi":          (5.0,  NONE, "PKT",  "",     "Karachi, Tashkent"),
    "Asia/Kolkata":          (5.5,  NONE, "IST",  "",     "Mumbai, Delhi, Colombo"),
    "Asia/Kathmandu":        (5.75, NONE, "+0545", "",    "Kathmandu"),
    "Asia/Dhaka":            (6.0,  NONE, "+06",  "",     "Dhaka, Almaty"),
    "Asia/Bangkok":          (7.0,  NONE, "+07",  "",     "Bangkok, Hanoi, Jakarta"),
    "Asia/Shanghai":         (8.0,  NONE, "CST",  "",     "Shanghai, Beijing, Hong Kong"),
    "Asia/Singapore":        (8.0,  NONE, "+08",  "",     "Singapore, Kuala Lumpur, Perth"),
    "Asia/Tokyo":            (9.0,  NONE, "JST",  "",     "Tokyo, Seoul"),
    # ---- Oceania ---------------------------------------------------------- #
    "Australia/Brisbane":    (10.0, NONE, "AEST", "",     "Brisbane (no DST)"),
    "Australia/Sydney":      (10.0, AU,   "AEST", "AEDT", "Sydney, Melbourne, Canberra"),
    "Australia/Adelaide":    (9.5,  AU,   "ACST", "ACDT", "Adelaide"),
    "Australia/Darwin":      (9.5,  NONE, "ACST", "",     "Darwin (no DST)"),
    "Australia/Perth":       (8.0,  NONE, "AWST", "",     "Perth (no DST)"),
    "Pacific/Auckland":      (12.0, NZ,   "NZST", "NZDT", "Auckland, Wellington"),
    # ---- Fixed offset ----------------------------------------------------- #
    # Not a place: use it when the time you have is ALREADY in UTC (a satellite
    # pass, a log timestamp, a spec written in Zulu time). For a site on the
    # ground you almost always want its local wall-clock zone instead.
    "UTC":                   (0.0,  NONE, "UTC",  "",     "UTC / GMT - times already in UTC"),
}


def zone_keys() -> list[str]:
    """Zone keys, `DEFAULT_ZONE` first, then alphabetical."""
    keys = sorted(ZONES)
    if DEFAULT_ZONE in keys:
        keys.remove(DEFAULT_ZONE)
        keys.insert(0, DEFAULT_ZONE)
    return keys


# --------------------------------------------------------------------------- #
#  Transition dates
# --------------------------------------------------------------------------- #
def _nth_sunday(year: int, month: int, n: int) -> date:
    """`n`-th Sunday of a month; `n = -1` means the last one."""
    if n > 0:
        first = date(year, month, 1)
        return first + timedelta(days=(6 - first.weekday()) % 7 + 7 * (n - 1))
    last_day = (date(year + (month == 12), month % 12 + 1, 1) - timedelta(days=1))
    return last_day - timedelta(days=(last_day.weekday() + 1) % 7)


def _dst_window(rule: str, year: int, std_offset: float):
    """(start, end) of the DST period as naive local standard-time datetimes."""
    if rule == EU:
        # transitions happen at 01:00 UTC across the whole union
        shift = timedelta(hours=1 + std_offset)
        return (datetime.combine(_nth_sunday(year, 3, -1), datetime.min.time()) + shift,
                datetime.combine(_nth_sunday(year, 10, -1), datetime.min.time()) + shift)
    if rule == US:
        return (datetime.combine(_nth_sunday(year, 3, 2), datetime.min.time())
                + timedelta(hours=2),
                datetime.combine(_nth_sunday(year, 11, 1), datetime.min.time())
                + timedelta(hours=2))
    if rule == AU:
        return (datetime.combine(_nth_sunday(year, 10, 1), datetime.min.time())
                + timedelta(hours=2),
                datetime.combine(_nth_sunday(year, 4, 1), datetime.min.time())
                + timedelta(hours=2))
    if rule == NZ:
        return (datetime.combine(_nth_sunday(year, 9, -1), datetime.min.time())
                + timedelta(hours=2),
                datetime.combine(_nth_sunday(year, 4, 1), datetime.min.time())
                + timedelta(hours=2))
    raise ValueError(f"unknown DST rule: {rule!r}")


def _is_dst(rule: str, std_offset: float, naive_local: datetime) -> bool:
    if rule == NONE:
        return False
    start, end = _dst_window(rule, naive_local.year, std_offset)
    if rule in (AU, NZ):
        # southern hemisphere: the DST period straddles the new year
        return naive_local >= start or naive_local < end
    return start <= naive_local < end


# --------------------------------------------------------------------------- #
#  Public API
# --------------------------------------------------------------------------- #
def zone_offset(key: str, naive_local: datetime):
    """(tzinfo, offset_hours, abbreviation, is_dst) for a local wall-clock time.

    `naive_local` is the wall-clock time on site, exactly as typed by the user.
    """
    try:
        std, rule, std_abbr, dst_abbr, _label = ZONES[key]
    except KeyError:
        raise ZoneError(
            f"unknown zone: {key!r}. Known zones: {', '.join(zone_keys())}"
        ) from None

    dst = _is_dst(rule, std, naive_local)
    offset = std + 1.0 if dst else std
    abbr = (dst_abbr or std_abbr) if dst else std_abbr
    return timezone(timedelta(hours=offset)), offset, abbr, dst


def zone_warning(key: str, naive_local: datetime) -> str:
    """Warning string, or "" when the answer can be trusted.

    Fires for dates predating the zone's current DST rule, where this frozen
    table is simply wrong and the IANA database (`auto` mode) should be used.
    """
    try:
        _std, rule, _sa, _da, _label = ZONES[key]
    except KeyError:
        raise ZoneError(f"unknown zone: {key!r}") from None
    since = RULE_SINCE.get(rule, 0)
    if since and naive_local.year < since:
        return (f"{key}: the daylight-saving rule used here only took its "
                f"current form in {since}. For {naive_local.year}, use the IANA "
                f"database ('auto' mode) instead of this offline table.")
    return ""


def describe(key: str, naive_local: datetime) -> str:
    """One-line human summary, e.g. 'Europe/Paris (CEST, UTC+2, DST active)'."""
    _tz, offset, abbr, dst = zone_offset(key, naive_local)
    return "%s (%s, UTC%+g, %s)" % (
        key, abbr, offset, "DST active" if dst else "standard time")
