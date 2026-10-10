"""Modelo de referencia del EA GG_LondonSweepFVG (sin dependencias externas).

Replica, línea a línea, dos partes críticas del .mq5 para poder verificarlas
fuera de MetaTrader:

1. Conversión de horarios (servidor <-> UTC <-> Madrid / Nueva York) y cálculo
   de la ventana diaria. Se contrasta contra la base de datos IANA (zoneinfo)
   para todos los días laborables de 2024-2028.
2. Cálculo del plan de órdenes (L1, L2, SL, TP1, TP2, volumen, riesgo) para
   comparar con las líneas "SETUP ..." del log del EA (operaciones de
   referencia calculadas a mano).

Uso:
    python3 tests/reference_model.py            # ejecuta las verificaciones
    python3 tests/reference_model.py plan SELL 21000 21020 --vpp 1 --step 0.01
"""

import argparse
import math
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# ---------------------------------------------------------------- horarios
SERVER_WINTER = 2          # InpServerGmtOffsetWinter
SERVER_DST = "US"          # InpServerDst
START = (9, 0)             # InpStartHourMadrid / Minute
SETUP_END = (11, 0)        # InpSetupEndHourMadrid / Minute
NY_CUTOFF = (9, 30)        # InpNyCutoffHour / Minute

EPOCH = datetime(1970, 1, 1)


def ts(dt):
    return int((dt - EPOCH).total_seconds())


def from_ts(t):
    return EPOCH + timedelta(seconds=t)


def make_time(y, m, d, hh=0, mm=0):
    return ts(datetime(y, m, d, hh, mm))


def day_of_week(t):  # 0 = domingo, como MqlDateTime.day_of_week
    return (from_ts(t).weekday() + 1) % 7


def nth_sunday(y, m, n):
    first = make_time(y, m, 1)
    offset = (7 - day_of_week(first)) % 7
    return first + (offset + 7 * (n - 1)) * 86400


def last_sunday(y, m):
    ny, nm = (y + 1, 1) if m == 12 else (y, m + 1)
    first_next = make_time(ny, nm, 1)
    dow = day_of_week(first_next)
    back = 7 if dow == 0 else dow
    return first_next - back * 86400


def is_us_dst(utc):
    y = from_ts(utc).year
    return nth_sunday(y, 3, 2) + 7 * 3600 <= utc < nth_sunday(y, 11, 1) + 6 * 3600


def is_eu_dst(utc):
    y = from_ts(utc).year
    return last_sunday(y, 3) + 3600 <= utc < last_sunday(y, 10) + 3600


def server_offset_from_utc(utc):
    dst = is_us_dst(utc) if SERVER_DST == "US" else is_eu_dst(utc) if SERVER_DST == "EU" else False
    return SERVER_WINTER * 3600 + (3600 if dst else 0)


def server_to_utc(srv):
    return srv - server_offset_from_utc(srv - SERVER_WINTER * 3600)


def utc_to_server(utc):
    return utc + server_offset_from_utc(utc)


def madrid_offset(utc):
    return 3600 + (3600 if is_eu_dst(utc) else 0)


def new_york_offset(utc):
    return -5 * 3600 + (3600 if is_us_dst(utc) else 0)


def compute_session(server_now):
    utc_now = server_to_utc(server_now)
    md = from_ts(utc_now + madrid_offset(utc_now))
    noon = make_time(md.year, md.month, md.day, 12, 0)
    mo = madrid_offset(noon)
    no = new_york_offset(noon + 5 * 3600)
    start = make_time(md.year, md.month, md.day, *START) - mo
    setup_end = make_time(md.year, md.month, md.day, *SETUP_END) - mo
    cutoff = make_time(md.year, md.month, md.day, *NY_CUTOFF) - no
    setup_end = min(setup_end, cutoff)
    return {
        "day": md.date(),
        "trading": day_of_week(make_time(md.year, md.month, md.day)) in range(1, 6),
        "start": utc_to_server(start),
        "setup_end": utc_to_server(setup_end),
        "cutoff": utc_to_server(cutoff),
    }


def verify_sessions():
    """Compara el algoritmo del EA con zoneinfo para cada día laborable."""
    mad, nyc = ZoneInfo("Europe/Madrid"), ZoneInfo("America/New_York")
    srv_tz = ZoneInfo("America/New_York")  # servidor GMT+2/+3 con DST de EE. UU.
    errors, days = 0, 0
    d = datetime(2024, 1, 1)
    while d < datetime(2029, 1, 1):
        if d.weekday() < 5:
            days += 1
            exp_start = datetime(d.year, d.month, d.day, *START, tzinfo=mad).astimezone(timezone.utc)
            exp_cut = datetime(d.year, d.month, d.day, *NY_CUTOFF, tzinfo=nyc).astimezone(timezone.utc)

            def utc_to_srv_ref(u):
                dst = bool(u.astimezone(srv_tz).dst())
                return u.replace(tzinfo=None) + timedelta(hours=SERVER_WINTER + (1 if dst else 0))

            # se evalúa a las 12:00 de Madrid (dentro de la sesión)
            probe_utc = datetime(d.year, d.month, d.day, 12, 0, tzinfo=mad).astimezone(timezone.utc)
            probe_srv = ts(utc_to_srv_ref(probe_utc))
            s = compute_session(probe_srv)
            if (s["day"] != d.date() or not s["trading"]
                    or s["start"] != ts(utc_to_srv_ref(exp_start))
                    or s["cutoff"] != ts(utc_to_srv_ref(exp_cut))):
                errors += 1
                print("DISCREPANCIA", d.date(), s)
        d += timedelta(days=1)
    print(f"Horarios: {days} días laborables 2024-2028 verificados, discrepancias: {errors}")
    return errors == 0


def show_examples():
    for y, m, dd in [(2026, 1, 15), (2026, 3, 10), (2026, 4, 15), (2026, 10, 28), (2026, 11, 3)]:
        probe_utc = datetime(y, m, dd, 11, 0, tzinfo=timezone.utc)
        srv = ts(probe_utc.replace(tzinfo=None)) + server_offset_from_utc(ts(probe_utc.replace(tzinfo=None)))
        s = compute_session(srv)
        f = lambda t: from_ts(t).strftime("%H:%M")
        cut_utc = server_to_utc(s["cutoff"])
        cut_mad = from_ts(cut_utc + madrid_offset(cut_utc)).strftime("%H:%M")
        print(f"  {s['day']}: servidor inicio {f(s['start'])}, setups hasta {f(s['setup_end'])}, "
              f"cierre NY {f(s['cutoff'])} (= {cut_mad} Madrid)")


# -------------------------------------------------------------- plan/riesgo
def floor_tick(p, tick):
    return math.floor(p / tick + 1e-9) * tick


def ceil_tick(p, tick):
    return math.ceil(p / tick - 1e-9) * tick


def round_tick(p, tick):
    return round(p / tick) * tick


def build_plan(direction, zone_low, zone_high, vpp, step, vmin=0.01, tick=0.01,
               risk=800.0, tp=500.0, sl_dist=66.7, buffer=0.0, commission=0.0):
    """vpp = valor (divisa de la cuenta) de 1.0 de precio por 1 lote."""
    if direction == "SELL":
        l1, l2 = round_tick(zone_low, tick), round_tick(zone_high + buffer, tick)
        avg = (l1 + l2) / 2
        sl = floor_tick(avg + sl_dist, tick)
        if sl <= l2:
            return {"error": "FVG demasiado ancho: SL no queda más allá de L2"}
        loss_pair = (sl - l1) * vpp + (sl - l2) * vpp
    else:
        l1, l2 = round_tick(zone_high, tick), round_tick(zone_low - buffer, tick)
        avg = (l1 + l2) / 2
        sl = ceil_tick(avg - sl_dist, tick)
        if sl >= l2:
            return {"error": "FVG demasiado ancho: SL no queda más allá de L2"}
        loss_pair = (l1 - sl) * vpp + (l2 - sl) * vpp
    raw = risk / (loss_pair + 4 * commission)
    vol = math.floor(raw / step + 1e-9) * step
    if vol < vmin - 1e-12:
        return {"error": "volumen por debajo del mínimo"}
    d1 = tp / (vol * vpp)
    d2 = tp / (2 * vol * vpp)
    if direction == "SELL":
        tp1, tp2 = floor_tick(l1 - d1, tick), floor_tick(avg - d2, tick)
    else:
        tp1, tp2 = ceil_tick(l1 + d1, tick), ceil_tick(avg + d2, tick)
    sign = 1 if direction == "BUY" else -1
    return {
        "L1": l1, "L2": l2, "precio_medio": avg, "SL": sl, "TP1": tp1, "TP2": tp2,
        "lotes_por_orden": round(vol, 8),
        "riesgo_ambas_llenas": vol * (loss_pair + 4 * commission),
        "beneficio_solo_L1_en_TP1": vol * vpp * sign * (tp1 - l1),
        "beneficio_ambas_en_TP2": vol * vpp * sign * ((tp2 - l1) + (tp2 - l2)),
    }


def verify_plans():
    ok = True
    for direction, lo, hi in [("SELL", 21000.0, 21020.0), ("BUY", 20950.0, 20980.0)]:
        for vpp, step in [(1.0, 0.01), (10.0, 0.01), (0.1, 0.1)]:
            p = build_plan(direction, lo, hi, vpp, step)
            if "error" in p:
                print("  ", direction, vpp, p["error"])
                continue
            cond = (p["riesgo_ambas_llenas"] <= 800.0 + 1e-6
                    and p["beneficio_solo_L1_en_TP1"] >= 500.0 - 1e-6
                    and p["beneficio_ambas_en_TP2"] >= 500.0 - 1e-6)
            ok &= cond
            print(f"  {direction} vpp={vpp} paso={step}: lotes={p['lotes_por_orden']}, SL={p['SL']:.2f}, "
                  f"TP1={p['TP1']:.2f}, TP2={p['TP2']:.2f}, riesgo={p['riesgo_ambas_llenas']:.2f}, "
                  f"+L1={p['beneficio_solo_L1_en_TP1']:.2f}, +ambas={p['beneficio_ambas_en_TP2']:.2f} "
                  f"{'OK' if cond else 'FALLO'}")
    wide = build_plan("SELL", 21000.0, 21140.0, 1.0, 0.01)
    ok &= "error" in wide
    print("  FVG de 140 puntos:", wide.get("error", "NO RECHAZADO (FALLO)"))
    return ok


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "plan":
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd")
        ap.add_argument("direction", choices=["SELL", "BUY"])
        ap.add_argument("zone_low", type=float)
        ap.add_argument("zone_high", type=float)
        ap.add_argument("--vpp", type=float, required=True, help="valor de 1.0 de precio por lote")
        ap.add_argument("--step", type=float, default=0.01)
        ap.add_argument("--vmin", type=float, default=0.01)
        ap.add_argument("--tick", type=float, default=0.01)
        ap.add_argument("--commission", type=float, default=0.0)
        a = ap.parse_args()
        print(build_plan(a.direction, a.zone_low, a.zone_high, a.vpp, a.step, a.vmin, a.tick,
                         commission=a.commission))
        return 0
    print("Ejemplos de ventana (servidor GMT+2/+3, DST EE. UU.):")
    show_examples()
    good = verify_sessions()
    print("Plan de órdenes:")
    good &= verify_plans()
    print("RESULTADO:", "OK" if good else "FALLOS")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
