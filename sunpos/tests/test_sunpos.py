#!/usr/bin/env python3
"""
Regression tests for aioli-sunpos.

Run either way:
    python -m pytest tests -q
    python tests/test_sunpos.py          (works without pytest installed)

Reference values come from published solar tables (NOAA / timeanddate) for
Paris, Sydney and Auckland, and from Meeus for the Julian day.
"""

import math
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from sunpos_core import (                                          # noqa: E402
    HORIZON_DEG, PolarDayNight, _solar_terms, apparent_elevation, compute_sun,
    direction_to_xyz, distance_for_zmax, julian_day, noon_elevation,
    parse_location, refraction_deg, solar_position, sun_events, sun_path,
)
from sunpos_zones import (                                         # noqa: E402
    ZoneError, zone_keys, zone_offset, zone_warning,
)

PARIS = (48.840006, 2.276764)
SYDNEY = (-33.8599, 151.2091)
TZ2 = timezone(timedelta(hours=2))       # Paris, summer
TZ10 = timezone(timedelta(hours=10))     # Sydney, standard time
TZ11 = timezone(timedelta(hours=11))     # Sydney, summer
TZ13 = timezone(timedelta(hours=13))     # Auckland, summer


# ---------------------------------------------------------------- parsing --- #
def test_parse_plain():
    assert parse_location("48.840006, 2.276764") == (48.840006, 2.276764)
    assert parse_location("-33.8599,151.2091") == (-33.8599, 151.2091)


def test_parse_maps_urls():
    lat, lon = parse_location(
        "https://www.google.com/maps/@-33.8600841,151.2095012,3a,60y,90t/data=!3m7")
    assert abs(lat + 33.8600841) < 1e-9 and abs(lon - 151.2095012) < 1e-9
    lat, lon = parse_location("https://maps.google.com/?q=48.8584,2.2945")
    assert (round(lat, 4), round(lon, 4)) == (48.8584, 2.2945)
    lat, lon = parse_location("https://www.google.com/maps/place/x/data=!3d48.85!4d2.29")
    assert (lat, lon) == (48.85, 2.29)


def test_parse_rejects_garbage_and_out_of_range():
    for bad in ("hello", "", "200,10", "10,400", "48.84"):
        try:
            parse_location(bad)
        except ValueError:
            continue
        raise AssertionError("should have raised ValueError: %r" % bad)


# ------------------------------------------------- NOAA algorithm / year --- #
def test_julian_day_reference_values():
    """Reference values from Meeus, "Astronomical Algorithms"."""
    for dt, want in (
            (datetime(2000, 1, 1, 12, tzinfo=timezone.utc), 2451545.0),
            (datetime(1987, 1, 27, 0, tzinfo=timezone.utc), 2446822.5),
            (datetime(1957, 10, 4, 19, 26, 24, tzinfo=timezone.utc), 2436116.31),
            (datetime(2026, 8, 5, 0, tzinfo=timezone.utc), 2461257.5)):
        assert abs(julian_day(dt) - want) < 1e-2, (dt, julian_day(dt), want)


def test_equation_of_time_extremes():
    """The equation of time reaches about -14.2 min in mid-February and
    +16.4 min in early November. This is what separates a real NOAA
    implementation from a coarse approximation."""
    _, feb = _solar_terms(datetime(2026, 2, 11, 12, tzinfo=timezone.utc))
    _, nov = _solar_terms(datetime(2026, 11, 3, 12, tzinfo=timezone.utc))
    assert abs(feb - (-14.2)) < 0.3, feb
    assert abs(nov - 16.4) < 0.3, nov


def test_solstice_declination():
    """Declination at the solstices: +-23.44 deg (obliquity of the ecliptic)."""
    jun, _ = _solar_terms(datetime(2026, 6, 21, 12, tzinfo=timezone.utc))
    dec, _ = _solar_terms(datetime(2026, 12, 21, 12, tzinfo=timezone.utc))
    assert abs(math.degrees(jun) - 23.44) < 0.05, math.degrees(jun)
    assert abs(math.degrees(dec) + 23.44) < 0.05, math.degrees(dec)


def test_equinox_declination_near_zero():
    for date in (datetime(2026, 3, 20, 14, 46, tzinfo=timezone.utc),
                 datetime(2026, 9, 23, 0, 5, tzinfo=timezone.utc)):
        decl, _ = _solar_terms(date)
        assert abs(math.degrees(decl)) < 0.05, (date, math.degrees(decl))


def test_year_actually_changes_the_sun():
    """REGRESSION: the old "fractional year" approximation was blind to the
    year - 2021, 2026 and 2027 produced an identical sun. The position really
    does drift (tropical year = 365.2422 d, caught up by leap years)."""
    els = [solar_position(*SYDNEY, datetime(y, 9, 21, 9, 30, tzinfo=TZ10))[1]
           for y in (2021, 2024, 2026, 2027, 2028)]
    assert len(set(round(e, 6) for e in els)) == len(els), els
    spread = max(els) - min(els)
    assert 0.05 < spread < 1.0, spread


def test_leap_cycle_repeats_closely():
    """A 4-year cycle brings back almost the same sun (within ~0.1 deg)."""
    a = solar_position(*SYDNEY, datetime(2024, 9, 21, 9, 30, tzinfo=TZ10))
    b = solar_position(*SYDNEY, datetime(2028, 9, 21, 9, 30, tzinfo=TZ10))
    assert abs(a[1] - b[1]) < 0.1, (a, b)


# ------------------------------------------------------------ refraction --- #
def test_refraction_magnitudes():
    """~0.5 deg at the horizon, small but non-zero mid-sky, zero at the zenith."""
    assert 0.4 < refraction_deg(0.0) < 0.65, refraction_deg(0.0)
    assert 0.01 < refraction_deg(45.0) < 0.03, refraction_deg(45.0)
    assert refraction_deg(90.0) == 0.0


def test_refraction_is_monotonic():
    vals = [refraction_deg(e) for e in range(0, 91)]
    assert all(a >= b - 1e-12 for a, b in zip(vals, vals[1:])), "not decreasing"


def test_refraction_lifts_the_sun():
    for el in (-0.5, 0.0, 5.0, 30.0, 80.0):
        assert apparent_elevation(el) >= el


def test_refraction_matters_at_the_horizon_only():
    """The whole point: negligible high up, decisive near the horizon."""
    assert abs(apparent_elevation(40.0) - 40.0) < 0.03
    assert apparent_elevation(0.5) - 0.5 > 0.3


def test_no_refraction_flag_is_geometric():
    a = compute_sun(PARIS, datetime(2026, 6, 21, 21, 30), TZ2, refraction=False)
    b = compute_sun(PARIS, datetime(2026, 6, 21, 21, 30), TZ2, refraction=True)
    assert a.refraction_deg == 0.0
    assert a.elevation_deg == a.geometric_elevation_deg
    assert b.elevation_deg > a.elevation_deg


# ------------------------------------------------------ solar positions --- #
def test_paris_summer_solstice_noon():
    """21 June, solar noon in Paris: el ~ 64.6, az ~ 180 (due South)."""
    ev = sun_events(*PARIS, datetime(2026, 6, 21, 12, tzinfo=TZ2))
    az, el = solar_position(*PARIS, ev["noon"])
    assert abs(el - (90 - abs(PARIS[0] - 23.44))) < 0.5, el
    assert abs(az - 180.0) < 0.5, az


def test_sydney_culminates_north():
    """Southern hemisphere: the sun culminates to the NORTH (az ~ 0 / 360)."""
    ev = sun_events(*SYDNEY, datetime(2026, 11, 21, 12, tzinfo=TZ11))
    az, el = solar_position(*SYDNEY, ev["noon"])
    assert min(abs(az), abs(az - 360)) < 1.0, az
    assert abs(el - (90 - abs(SYDNEY[0] - (-19.9)))) < 1.0, el


def test_sunrise_sunset_paris_solstice():
    """Observed reference: sunrise 05:47, noon 13:52, sunset 21:58 (CEST)."""
    ev = sun_events(*PARIS, datetime(2026, 6, 21, 12, tzinfo=TZ2))
    for key, want in (("sunrise", "05:47"), ("noon", "13:52"), ("sunset", "21:58")):
        got = ev[key]
        ref = datetime.strptime(want, "%H:%M").replace(
            year=2026, month=6, day=21, tzinfo=TZ2)
        assert abs((got - ref).total_seconds()) < 180, (key, got, want)
    assert abs(ev["day_length_h"] - 16.18) < 0.1, ev["day_length_h"]


def test_sunrise_sunset_beyond_utc12():
    """REGRESSION: zones beyond +12 h used to shift the date by one day.
    Auckland (UTC+13) on 2026-01-15: sunrise ~06:11, sunset ~20:41 NZDT."""
    ev = sun_events(-36.8485, 174.7633, datetime(2026, 1, 15, 12, tzinfo=TZ13))
    for key in ("sunrise", "noon", "sunset"):
        assert ev[key].date() == datetime(2026, 1, 15).date(), (key, ev[key])
    assert abs(ev["sunrise"].hour * 60 + ev["sunrise"].minute - (6 * 60 + 11)) < 15
    assert abs(ev["sunset"].hour * 60 + ev["sunset"].minute - (20 * 60 + 41)) < 15


def test_elevation_at_sunrise_is_horizon_threshold():
    ev = sun_events(*PARIS, datetime(2026, 6, 21, 12, tzinfo=TZ2))
    for key in ("sunrise", "sunset"):
        _, el = solar_position(*PARIS, ev[key])
        assert abs(el - HORIZON_DEG) < 0.1, (key, el)


def test_symmetry_around_solar_noon():
    ev = sun_events(*PARIS, datetime(2026, 3, 20, 12, tzinfo=TZ2))
    for dh in (1, 2, 3, 4):
        _, a = solar_position(*PARIS, ev["noon"] - timedelta(hours=dh))
        _, b = solar_position(*PARIS, ev["noon"] + timedelta(hours=dh))
        assert abs(a - b) < 0.15, (dh, a, b)


def test_equinox_rises_east_sets_west():
    ev = sun_events(*PARIS, datetime(2026, 3, 20, 12, tzinfo=TZ2))
    az_rise, _ = solar_position(*PARIS, ev["sunrise"])
    az_set, _ = solar_position(*PARIS, ev["sunset"])
    assert abs(az_rise - 90) < 2.0, az_rise
    assert abs(az_set - 270) < 2.0, az_set


# --------------------------------------------------- scene conventions --- #
def test_north_rotation_convention():
    """Az = 0 (true North) must land on (-sin R, cos R)."""
    for R in (0, 5, 90, 121, 180, 270, 359):
        x, y, z = direction_to_xyz(0.0, 0.0, R, 1.0, (0, 0, 0))
        assert abs(x - (-math.sin(math.radians(R)))) < 1e-9, R
        assert abs(y - math.cos(math.radians(R))) < 1e-9, R
        assert abs(z) < 1e-9


def test_target_offset_is_additive():
    a = direction_to_xyz(137.0, 42.0, 17.0, 2000.0, (0, 0, 0))
    b = direction_to_xyz(137.0, 42.0, 17.0, 2000.0, (100, -250, 30))
    assert [round(v, 6) for v in b] == [round(a[0] + 100, 6),
                                        round(a[1] - 250, 6),
                                        round(a[2] + 30, 6)]


def test_distance_does_not_change_direction():
    """Scaling the distance does not change the direction (parallel rays)."""
    p = direction_to_xyz(210.0, 35.0, 42.0, 1000.0, (0, 0, 0))
    q = direction_to_xyz(210.0, 35.0, 42.0, 7000.0, (0, 0, 0))
    n = math.sqrt(sum(v * v for v in p))
    m = math.sqrt(sum(v * v for v in q))
    for a, b in zip(p, q):
        assert abs(a / n - b / m) < 1e-12


def test_zmax_is_reached_at_solar_noon():
    ref = datetime(2026, 6, 21, 12, tzinfo=TZ2)
    dist, note = distance_for_zmax(*PARIS, ref, 1500.0)
    assert note == ""
    ev = sun_events(*PARIS, ref)
    _, el = solar_position(*PARIS, ev["noon"])
    z = direction_to_xyz(0, apparent_elevation(el), 0, dist, (0, 0, 0))[2]
    assert abs(z - 1500.0) < 5.0, z


def test_path_shares_one_distance_and_stays_under_zmax():
    rows = sun_path(PARIS, datetime(2026, 6, 21), TZ2, step_hours=0.5,
                    north_rotation_deg=121, z_max_cm=1500.0)
    assert len({r.distance_cm for r in rows}) == 1
    assert max(r.Z_cm for r in rows) <= 1500.0 + 1.0
    assert rows[0].horizon == "on" and rows[-1].horizon == "on"
    assert all(r.horizon == "above" for r in rows[1:-1])


def test_path_endpoints_are_sunrise_and_sunset():
    ev = sun_events(*SYDNEY, datetime(2026, 11, 21, 12, tzinfo=TZ11))
    rows = sun_path(SYDNEY, datetime(2026, 11, 21), TZ11, step_hours=3.0)
    assert rows[0].local_time == ev["sunrise"].strftime("%Y-%m-%d %H:%M")
    assert rows[-1].local_time == ev["sunset"].strftime("%Y-%m-%d %H:%M")


# ------------------------------------------------------------ edge cases --- #
def test_polar_night_raises():
    try:
        sun_events(78.0, 15.0, datetime(2026, 12, 21, 12, tzinfo=TZ2))
    except PolarDayNight as exc:
        assert exc.kind == "night"
    else:
        raise AssertionError("PolarDayNight expected")


def test_polar_day_raises():
    try:
        sun_events(78.0, 15.0, datetime(2026, 6, 21, 12, tzinfo=TZ2))
    except PolarDayNight as exc:
        assert exc.kind == "day"
    else:
        raise AssertionError("PolarDayNight expected")


def test_polar_night_distance_is_sane():
    ref = datetime(2026, 12, 21, 12, tzinfo=TZ2)
    assert noon_elevation(78.0, 15.0, ref) < 0
    dist, note = distance_for_zmax(78.0, 15.0, ref, 1500.0)
    assert dist == 1500.0 and note != ""


def test_compute_sun_rejects_aware_datetime():
    try:
        compute_sun(PARIS, datetime(2026, 6, 21, 12, tzinfo=TZ2), TZ2)
    except ValueError:
        return
    raise AssertionError("ValueError expected for an aware datetime")


def test_dst_ambiguous_time_is_flagged():
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Europe/Paris")
    except Exception:
        return                                   # no tzdata: skip
    res = compute_sun(PARIS, datetime(2026, 10, 25, 2, 30), tz)
    assert "ambiguous" in res.note.lower(), res.note


def test_night_is_flagged_below_horizon():
    res = compute_sun(PARIS, datetime(2026, 12, 21, 2, 0), TZ2)
    assert res.horizon == "below" and res.Z_cm < 0
    assert not res.above_horizon


def test_equator_solstice_noon_elevation():
    el = noon_elevation(0.0, 0.0, datetime(2026, 6, 21, 12, tzinfo=timezone.utc),
                        refraction=False)
    assert abs(el - 66.55) < 0.3, el


# ------------------------------------------------------- offline zone table --- #
def test_zone_table_dst_transitions():
    """Each case is a legislated transition date, checked either side."""
    cases = [
        ("Europe/Paris", datetime(2026, 1, 15, 12), 1.0, "CET"),
        ("Europe/Paris", datetime(2026, 7, 15, 12), 2.0, "CEST"),
        ("Europe/Paris", datetime(2026, 3, 28, 12), 1.0, "CET"),    # before 29/03
        ("Europe/Paris", datetime(2026, 3, 30, 12), 2.0, "CEST"),
        ("Europe/Paris", datetime(2026, 10, 24, 12), 2.0, "CEST"),  # before 25/10
        ("Europe/Paris", datetime(2026, 10, 26, 12), 1.0, "CET"),
        ("Australia/Sydney", datetime(2026, 9, 21, 9, 30), 10.0, "AEST"),
        ("Australia/Sydney", datetime(2026, 11, 21, 11, 41), 11.0, "AEDT"),
        ("Australia/Sydney", datetime(2026, 4, 3, 12), 11.0, "AEDT"),
        ("Australia/Sydney", datetime(2026, 4, 6, 12), 10.0, "AEST"),
        ("Pacific/Auckland", datetime(2026, 1, 15, 12), 13.0, "NZDT"),
        ("America/New_York", datetime(2026, 1, 15, 12), -5.0, "EST"),
        ("America/New_York", datetime(2026, 7, 15, 12), -4.0, "EDT"),
        ("America/Phoenix", datetime(2026, 7, 15, 12), -7.0, "MST"),
        ("Asia/Kolkata", datetime(2026, 7, 15, 12), 5.5, "IST"),
        ("UTC", datetime(2026, 7, 15, 12), 0.0, "UTC"),
    ]
    for key, dt, off, abbr in cases:
        _tz, got_off, got_abbr, _dst = zone_offset(key, dt)
        assert got_off == off, (key, dt, got_off, off)
        assert got_abbr == abbr, (key, dt, got_abbr, abbr)


def test_zone_table_matches_tzdata():
    """Where tzdata is available, the offline table must agree with it."""
    try:
        from zoneinfo import ZoneInfo
        ZoneInfo("Europe/Paris")
    except Exception:
        return                                   # no tzdata: skip
    for key in zone_keys():
        if key == "UTC":
            continue
        try:
            iana = ZoneInfo(key)
        except Exception:
            continue
        for month in range(1, 13):
            for day in (5, 20):
                dt = datetime(2026, month, day, 12)
                _tz, off, _abbr, _dst = zone_offset(key, dt)
                ref = dt.replace(tzinfo=iana).utcoffset().total_seconds() / 3600
                assert abs(off - ref) < 1e-9, (key, dt, off, ref)


def test_unknown_zone_raises():
    try:
        zone_offset("Mars/Olympus_Mons", datetime(2026, 1, 1, 12))
    except ZoneError:
        return
    raise AssertionError("ZoneError expected")


def test_zone_warning_flags_dates_before_the_current_rule():
    """The offline table is only valid from the year each rule took its current
    form. Before that it must say so rather than return a plausible number."""
    assert zone_warning("Europe/Paris", datetime(2026, 6, 21, 12)) == ""
    assert "2002" in zone_warning("Europe/Paris", datetime(1995, 6, 21, 12))
    assert "2007" in zone_warning("America/New_York", datetime(2005, 6, 21, 12))
    assert zone_warning("UTC", datetime(1900, 1, 1, 12)) == ""   # no DST rule


def test_year_outside_noaa_window_is_flagged():
    inside = compute_sun(PARIS, datetime(2026, 6, 21, 12), TZ2)
    outside = compute_sun(PARIS, datetime(2150, 6, 21, 12), TZ2)
    assert "outside" not in inside.note
    assert "2150" in outside.note and "1800-2100" in outside.note


def test_core_version_matches_max_tool():
    """A half-updated folder must fail loudly, not with a cryptic TypeError."""
    import sunpos_core
    import sunpos_max
    assert sunpos_core.CORE_VERSION == sunpos_max.REQUIRED_CORE_VERSION


def test_max_tool_does_not_reload_outside_max():
    """The reload hack swaps class objects; it must stay confined to Max, or
    every `except PolarDayNight` elsewhere silently stops matching."""
    import sunpos_max
    assert sunpos_max._HOST_IS_MAX is False
    assert sunpos_max.PolarDayNight is PolarDayNight


def test_default_zone_is_first():
    assert zone_keys()[0] == "Europe/Paris"


# ------------------------------------------------- parity with the Max tool --- #
def test_max_tool_matches_core():
    """The Max tool must produce exactly the same numbers as the core."""
    from sunpos_max import build_samples

    rows, src = build_samples(SYDNEY[0], SYDNEY[1], "2026-11-21", "11:41",
                              5.0, 1500.0, (0, 0, 0),
                              tz_mode="manual", utc_offset=11, mode="single")
    ref = compute_sun(SYDNEY, datetime(2026, 11, 21, 11, 41), TZ11,
                      north_rotation_deg=5.0, z_max_cm=1500.0)
    s = rows[0]
    assert "UTC+11" in src
    for key, want in (("x", ref.X_cm), ("y", ref.Y_cm), ("z", ref.Z_cm),
                      ("az", ref.azimuth_deg), ("el", ref.elevation_deg)):
        assert abs(s[key] - want) < 1e-6, (key, s[key], want)


def test_max_tool_zone_mode():
    from sunpos_max import build_samples
    rows, src = build_samples(SYDNEY[0], SYDNEY[1], "2026-09-21", "09:30",
                              0.0, 1500.0, (0, 0, 0), tz_mode="zone",
                              zone="Australia/Sydney", mode="single")
    assert "AEST" in src and "UTC+10" in src, src
    assert rows[0]["horizon"] == "above"


# --------------------------------------------------------------- CLI smoke --- #
def test_cli_accepts_negative_latitude_and_flags_anywhere():
    from sunpos_cli import main
    assert main(["--north", "5", "-33.8599,151.2091",
                 "2026-11-21 11:41", "--utc-offset", "11", "--json"]) == 0
    assert main(["-33.8599,151.2091", "2026-11-21",
                 "--path", "3", "--utc-offset", "11"]) == 0


def test_cli_zone_and_list_zones():
    from sunpos_cli import main
    assert main(["--list-zones"]) == 0
    assert main(["-33.8599,151.2091", "2026-09-21 09:30",
                 "--zone", "Australia/Sydney"]) == 0


def test_cli_reports_errors_cleanly():
    from sunpos_cli import main
    assert main(["not-a-place", "2026-01-01 12:00", "--utc-offset", "0"]) == 2
    assert main(["48.84,2.27", "01/01/2026", "--utc-offset", "1"]) == 2
    assert main(["48.84,2.27", "2026-01-01 12:00", "--utc-offset", "0",
                 "--target", "0,0"]) == 2
    assert main(["48.84,2.27", "2026-01-01 12:00", "--zone", "Nowhere/Land"]) == 2


# ============================================================================ #
if __name__ == "__main__":
    fns = [(n, f) for n, f in sorted(globals().items())
           if n.startswith("test_") and callable(f)]
    failed = []
    for name, fn in fns:
        try:
            fn()
            print("  ok    %s" % name)
        except Exception as exc:
            failed.append((name, exc))
            print("  FAIL  %s  ->  %s: %s" % (name, type(exc).__name__, exc))
    print("\n  %d/%d tests passed" % (len(fns) - len(failed), len(fns)))
    sys.exit(1 if failed else 0)
