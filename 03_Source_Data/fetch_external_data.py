"""
Fetch real external data (economic, fuel, weather) for the supply chain platform.

Unlike the other source scripts this one does not simulate anything - it calls public APIs:

    FRED (Federal Reserve)  construction spending, housing starts/permits (US + VA/WV/MD/DE),
                            construction employment, machinery prices, coal mining output,
                            inflation, mortgage rates, diesel and crude prices
    EIA                     regional retail diesel prices (Lower / Central Atlantic)   [needs key]
    NOAA NCEI               Storm Events database - severe weather in VA, WV, MD, DE
    NOAA NWS                active weather alerts right now (live snapshot)

API keys are read from environment variables and never written to disk:
    FRED_API_KEY  optional - without it, FRED's public CSV download is used instead
    EIA_API_KEY   optional - without it, regional diesel is skipped (national diesel still comes from FRED)

Outputs (under 03_Source_Data/external_data/):
    raw/<source>/<YYYY-MM-DD>/   untouched API responses (landing zone, git-ignored)
    economic_indicators.csv      long format: one row per series per date
    fuel_prices.csv              weekly diesel prices by region
    storm_events.csv             NOAA storm events since 2023 for the dealer territory
    weather_alerts_active.csv    alerts active at fetch time
    fetch_log.csv                what was fetched, when, how many rows, and whether it succeeded

Usage:
    python fetch_external_data.py
    python fetch_external_data.py --start 2015-01-01
"""

import argparse
import gzip
import io
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import requests

OUT = Path(__file__).parent / "external_data"
STATES = {"VA": "VIRGINIA", "WV": "WEST VIRGINIA", "MD": "MARYLAND", "DE": "DELAWARE"}
USER_AGENT = "AI-Supply-Chain-Decision-Intelligence-Platform (github.com/Dyadlapalli)"

# series_id: (name, category, geography, frequency, units)
FRED_SERIES = {
    "TTLCONS": ("Total Construction Spending", "Construction", "US", "Monthly", "Millions of USD, SAAR"),
    "TLNRESCONS": ("Nonresidential Construction Spending", "Construction", "US", "Monthly", "Millions of USD, SAAR"),
    "TLHWYCONS": ("Highway and Street Construction Spending", "Construction", "US", "Monthly",
                  "Millions of USD, SAAR"),
    "HOUST": ("Housing Starts", "Construction", "US", "Monthly", "Thousands of units, SAAR"),
    "VABPPRIVSA": ("New Private Housing Units Authorized", "Construction", "VA", "Monthly", "Units, SA"),
    "WVBPPRIVSA": ("New Private Housing Units Authorized", "Construction", "WV", "Monthly", "Units, SA"),
    "MDBPPRIVSA": ("New Private Housing Units Authorized", "Construction", "MD", "Monthly", "Units, SA"),
    "DEBPPRIVSA": ("New Private Housing Units Authorized", "Construction", "DE", "Monthly", "Units, SA"),
    "VACONS": ("Construction Employment", "Labor", "VA", "Monthly", "Thousands of persons, SA"),
    "WVCONS": ("Construction Employment", "Labor", "WV", "Monthly", "Thousands of persons, SA"),
    "SMS24000002000000001": ("Construction Employment", "Labor", "MD", "Monthly", "Thousands of persons, SA"),
    "WPU112": ("PPI - Construction Machinery and Equipment", "Prices", "US", "Monthly", "Index 1982=100"),
    "PCU333120333120": ("PPI - Construction Machinery Manufacturing", "Prices", "US", "Monthly",
                        "Index Dec 1984=100"),
    "CPIAUCSL": ("Consumer Price Index", "Prices", "US", "Monthly", "Index 1982-84=100, SA"),
    "IPN2121N": ("Industrial Production - Coal Mining", "Mining", "US", "Monthly", "Index 2017=100, NSA"),
    "IPG212S": ("Industrial Production - Mining (except Oil and Gas)", "Mining", "US", "Monthly",
                "Index 2017=100, SA"),
    "MORTGAGE30US": ("30-Year Fixed Mortgage Rate", "Finance", "US", "Weekly", "Percent"),
    "WTISPLC": ("WTI Crude Oil Spot Price", "Energy", "US", "Monthly", "USD per barrel"),
    "GASDESW": ("Retail Diesel Price", "Energy", "US", "Weekly", "USD per gallon"),
}
# EIA weekly retail No.2 diesel; PADD 1C covers VA/WV, PADD 1B covers MD/DE
EIA_DIESEL = {"EMD_EPD2D_PTE_R1Z_DPG": "Lower Atlantic (VA, WV)",
              "EMD_EPD2D_PTE_R1Y_DPG": "Central Atlantic (MD, DE)",
              "EMD_EPD2D_PTE_NUS_DPG": "US"}
STORM_INDEX = "https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/"


def redact(text: str) -> str:
    """Strip API keys from any text (error messages include the full request URL)."""
    text = re.sub(r"(api_key=)[^&\s'\"]+", r"\g<1>***", str(text))
    for var in ("FRED_API_KEY", "EIA_API_KEY"):
        secret = os.environ.get(var)
        if secret:
            text = text.replace(secret, "***")
    return text


def csv_safe(df: pd.DataFrame) -> pd.DataFrame:
    """Neutralise spreadsheet formula injection in free-text fields from third-party APIs."""
    out = df.copy()
    for col in out.select_dtypes(include="object"):
        out[col] = out[col].map(lambda v: "'" + v if isinstance(v, str) and v[:1] in ("=", "+", "-", "@") else v)
    return out


class Fetcher:
    def __init__(self, start):
        self.start = start
        self.today = datetime.now(timezone.utc).date().isoformat()
        self.retrieved_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.session = requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT
        self.log = []

    def get(self, url, params=None, retries=3):
        for attempt in range(retries):
            try:
                r = self.session.get(url, params=params, timeout=60)
                if r.status_code == 200:
                    return r
                if r.status_code in (429, 500, 502, 503, 504):
                    time.sleep(2 ** attempt)
                    continue
                r.raise_for_status()
            except requests.RequestException:
                if attempt == retries - 1:
                    raise
                time.sleep(2 ** attempt)
        raise RuntimeError(f"Gave up on {url}")

    def save_raw(self, source, name, content: bytes):
        d = OUT / "raw" / source / self.today
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_bytes(content)

    def record(self, source, dataset, status, rows=0, note=""):
        note = redact(note)
        self.log.append({"retrieved_at": self.retrieved_at, "source": source, "dataset": dataset,
                         "status": status, "rows": rows, "note": note})
        print(f"  {status:<7} {source:<5} {dataset:<24} {rows:>7,} rows  {note}")

    # --- FRED ----------------------------------------------------------------------------------------
    def fred(self):
        key = os.environ.get("FRED_API_KEY")
        frames = []
        for sid, (name, cat, geo, freq, units) in FRED_SERIES.items():
            try:
                if key:
                    r = self.get("https://api.stlouisfed.org/fred/series/observations",
                                 {"series_id": sid, "api_key": key, "file_type": "json",
                                  "observation_start": self.start})
                    self.save_raw("fred", f"{sid}.json", r.content)
                    df = pd.DataFrame(r.json()["observations"])[["date", "value"]]
                    method = "api"
                else:
                    r = self.get("https://fred.stlouisfed.org/graph/fredgraph.csv",
                                 {"id": sid, "cosd": self.start})
                    if not r.text.startswith("observation_date"):
                        raise ValueError("series not found")
                    self.save_raw("fred", f"{sid}.csv", r.content)
                    df = pd.read_csv(io.StringIO(r.text)).set_axis(["date", "value"], axis=1)
                    method = "public csv"
                df["value"] = pd.to_numeric(df["value"], errors="coerce")  # FRED uses "." for missing
                df = df.dropna(subset=["value"])
                df = df.assign(series_id=sid, series_name=name, category=cat, geography=geo, frequency=freq,
                               units=units, source="FRED", retrieved_at=self.retrieved_at)
                frames.append(df)
                self.record("FRED", sid, "ok", len(df), method)
            except Exception as e:  # keep going - one bad series shouldn't stop the run
                self.record("FRED", sid, "failed", note=str(e)[:80])
        if not frames:
            return pd.DataFrame()
        cols = ["series_id", "series_name", "category", "geography", "frequency", "units", "date", "value",
                "source", "retrieved_at"]
        return pd.concat(frames)[cols]

    # --- EIA -----------------------------------------------------------------------------------------
    def eia_diesel(self, fred_df):
        key = os.environ.get("EIA_API_KEY")
        rows = []
        if key:
            for sid, region in EIA_DIESEL.items():
                try:
                    r = self.get("https://api.eia.gov/v2/petroleum/pri/gnd/data/",
                                 {"api_key": key, "frequency": "weekly", "data[0]": "value",
                                  "facets[series][]": sid, "start": self.start, "length": 5000})
                    self.save_raw("eia", f"{sid}.json", r.content)
                    data = r.json()["response"]["data"]
                    for d in data:
                        rows.append({"week_of": d["period"], "region": region, "product": "No. 2 Diesel Retail",
                                     "price_usd_per_gal": float(d["value"]), "source": "EIA"})
                    self.record("EIA", sid, "ok", len(data))
                except Exception as e:
                    self.record("EIA", sid, "failed", note=str(e)[:80])
        else:
            self.record("EIA", "regional diesel", "skipped", note="set EIA_API_KEY to enable")
        if not any(r["region"] == "US" for r in rows) and not fred_df.empty:
            us = fred_df[fred_df.series_id == "GASDESW"]
            rows += [{"week_of": d, "region": "US", "product": "No. 2 Diesel Retail", "price_usd_per_gal": v,
                      "source": "FRED (EIA data)"} for d, v in zip(us.date, us.value)]
        df = pd.DataFrame(rows)
        if not df.empty:
            df["retrieved_at"] = self.retrieved_at
            df = df.sort_values(["region", "week_of"])
        return df

    # --- NOAA storm events ---------------------------------------------------------------------------
    def storms(self):
        index = self.get(STORM_INDEX).text
        first_year = int(self.start[:4])
        files = {}
        for name in set(re.findall(r'StormEvents_details-ftp_v1\.0_d(\d{4})_c(\d{8})\.csv\.gz', index)):
            year, created = name
            if int(year) >= max(first_year, 2023) and created > files.get(year, ("", ""))[1]:
                files[year] = (f"StormEvents_details-ftp_v1.0_d{year}_c{created}.csv.gz", created)
        frames = []
        for year, (fname, _) in sorted(files.items()):
            try:
                r = self.get(STORM_INDEX + fname)
                df = pd.read_csv(io.BytesIO(gzip.decompress(r.content)), low_memory=False)
                df = df[df.STATE.isin(STATES.values())]
                buf = io.BytesIO()
                df.to_csv(buf, index=False)
                self.save_raw("noaa_storms", fname.replace(".csv.gz", "_dealer_states.csv"), buf.getvalue())
                frames.append(df)
                self.record("NOAA", f"storm events {year}", "ok", len(df), fname)
            except Exception as e:
                self.record("NOAA", f"storm events {year}", "failed", note=str(e)[:80])
        if not frames:
            return pd.DataFrame()
        s = pd.concat(frames, ignore_index=True)

        def money(v):  # NOAA writes damage as "25.00K", "1.5M", "0.00K"
            if pd.isna(v) or v == "":
                return None
            m = re.match(r"^([\d.]+)([KMB]?)$", str(v).strip())
            if not m:
                return None
            return round(float(m.group(1)) * {"": 1, "K": 1e3, "M": 1e6, "B": 1e9}[m.group(2)], 2)

        state_code = {v: k for k, v in STATES.items()}
        out = pd.DataFrame({
            "event_id": s.EVENT_ID,
            "episode_id": s.EPISODE_ID,
            "state": s.STATE.map(state_code),
            "county_or_zone": s.CZ_NAME.str.title(),
            "zone_type": s.CZ_TYPE.map({"C": "County", "Z": "Forecast Zone", "M": "Marine"}),
            "event_type": s.EVENT_TYPE,
            "begin_datetime": pd.to_datetime(s.BEGIN_DATE_TIME, format="%d-%b-%y %H:%M:%S"),
            "end_datetime": pd.to_datetime(s.END_DATE_TIME, format="%d-%b-%y %H:%M:%S"),
            "timezone": s.CZ_TIMEZONE,
            "injuries": s.INJURIES_DIRECT + s.INJURIES_INDIRECT,
            "deaths": s.DEATHS_DIRECT + s.DEATHS_INDIRECT,
            "property_damage_usd": s.DAMAGE_PROPERTY.map(money),
            "crop_damage_usd": s.DAMAGE_CROPS.map(money),
            "magnitude": s.MAGNITUDE,
            "magnitude_type": s.MAGNITUDE_TYPE,
            "begin_lat": s.BEGIN_LAT,
            "begin_lon": s.BEGIN_LON,
            "source": "NOAA NCEI Storm Events",
            "retrieved_at": self.retrieved_at,
        })
        return out.sort_values("begin_datetime").reset_index(drop=True)

    # --- NOAA NWS active alerts ----------------------------------------------------------------------
    def alerts(self):
        rows = []
        for st in STATES:
            try:
                r = self.get("https://api.weather.gov/alerts/active", {"area": st})
                self.save_raw("nws_alerts", f"alerts_{st}_{datetime.now(timezone.utc):%H%M}.json", r.content)
                feats = r.json().get("features", [])
                for f in feats:
                    p = f["properties"]
                    rows.append({"alert_id": p.get("id"), "state": st, "event": p.get("event"),
                                 "severity": p.get("severity"), "urgency": p.get("urgency"),
                                 "certainty": p.get("certainty"), "headline": p.get("headline"),
                                 "area_desc": p.get("areaDesc"), "effective": p.get("effective"),
                                 "expires": p.get("expires"), "source": "NOAA NWS",
                                 "retrieved_at": self.retrieved_at})
                self.record("NWS", f"active alerts {st}", "ok", len(feats))
            except Exception as e:
                self.record("NWS", f"active alerts {st}", "failed", note=str(e)[:80])
        cols = ["alert_id", "state", "event", "severity", "urgency", "certainty", "headline", "area_desc",
                "effective", "expires", "source", "retrieved_at"]
        return pd.DataFrame(rows, columns=cols)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start", default="2018-01-01", help="earliest observation date (storms start 2023)")
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    f = Fetcher(args.start)
    print(f"Fetching external data since {args.start} ...")
    try:
        econ = f.fred()
    except Exception as e:  # never let a traceback print a URL containing a key
        raise SystemExit(f"FRED fetch failed: {redact(e)}") from None
    outputs = {
        "economic_indicators": econ,
        "fuel_prices": f.eia_diesel(econ),
        "storm_events": f.storms(),
        "weather_alerts_active": f.alerts(),
    }
    for name, df in outputs.items():
        if name != "weather_alerts_active" and df.empty:
            print(f"  ! {name} came back empty - keeping previous file")
            continue
        if name == "weather_alerts_active":
            df = csv_safe(df)  # headline / area text comes straight from a third party
        df.to_csv(OUT / f"{name}.csv", index=False)

    log_path = OUT / "fetch_log.csv"
    log = pd.DataFrame(f.log)
    if log_path.exists():  # keep history of runs for freshness monitoring
        log = pd.concat([pd.read_csv(log_path), log], ignore_index=True)
    log.to_csv(log_path, index=False)

    failed = sum(r["status"] == "failed" for r in f.log)
    print(f"\nDone -> {OUT}" + (f"  ({failed} source(s) failed, see fetch_log.csv)" if failed else ""))


if __name__ == "__main__":
    main()
