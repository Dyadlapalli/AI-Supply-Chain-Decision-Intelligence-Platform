# Source Data

This folder contains all source systems used by the Supply Chain Decision Intelligence Platform.

The solution simulates a real-world enterprise environment by integrating multiple data sources including SQL databases, Excel files, external APIs, business-managed files, and master data.

## Source Categories

- SQL
- Excel
- API
- CSV
- Master Data

## Generated Data

Internal source data (master, ERP, business files) is synthetic, generated to simulate a Caterpillar dealer's parts operation across 28 branches (VA, WV, MD, DE) from January 2023 to September 2026.

Each data set comes in two versions:

- **raw/** – messy data as it would arrive from source systems (duplicates, missing values, invalid references, inconsistent formats). This is the platform's input.
- **golden/** – the same data clean. Used only to validate data quality and cleansing results.
- **dq_issue_log.csv** – answer key listing every defect injected into raw/, tagged by data quality dimension (Completeness, Validity, Consistency, Uniqueness, Integrity) and severity.

| Folder | Contents | In Git |
|---|---|---|
| master_data/ | Branch, product family, product category, product, equipment, supplier, and part master (CSV + Excel) | Yes |
| erp_data/ | Sales orders, demand transactions, purchase orders, goods receipts, inventory transactions | Sample only |
| business_files/ | Planner-owned Excel and SharePoint files: safety stock targets, inventory policy, supplier exceptions, critical parts, forecast overrides | Yes |
| external_data/ | **Real** data from public APIs: economic indicators (FRED), diesel prices (FRED/EIA), storm events and active weather alerts (NOAA) | Yes (raw API responses git-ignored) |

### Rebuilding the data

Full ERP extracts (~100 MB) are not committed. A 1,000-row sample of each file is in `erp_data/sample/`. To regenerate everything:

```bash
pip install -r requirements.txt
python 03_Source_Data/generate_master_data.py   # run first - ERP data is built on master data
python 03_Source_Data/generate_erp_data.py
python 03_Source_Data/generate_business_files.py   # needs master + ERP data
```

Business files are messy at the file level, not just the value level: title blocks, merged cells, subtotal formulas, meaning held in cell colour, free-text supplier names, and an outdated version of the safety stock file still in circulation. Their `dq_issue_log.csv` records the file, sheet and cell of each issue.

Both scripts are deterministic (`--seed`, default 42) and accept `--scale` to change volume.

## External Data (real, from APIs)

`fetch_external_data.py` pulls live public data. Nothing in it is simulated.

| Output | Source | Contents |
|---|---|---|
| economic_indicators.csv | FRED | Construction spending (total, nonresidential, highway), housing starts, housing permits and construction jobs for VA/WV/MD/DE, construction machinery PPI, coal mining output, CPI, mortgage rates, crude oil, diesel |
| fuel_prices.csv | FRED / EIA | Weekly retail diesel: US, plus Lower Atlantic (VA, WV) and Central Atlantic (MD, DE) when an EIA key is set |
| storm_events.csv | NOAA NCEI | Severe weather events in VA, WV, MD, DE since 2023, with damage in USD |
| weather_alerts_active.csv | NOAA NWS | Weather alerts active at the time of the run |
| fetch_log.csv | — | Every fetch: when, source, rows, status. Used to monitor data freshness |

API keys are optional and read from environment variables (never committed):

```powershell
$env:FRED_API_KEY = "..."   # https://fred.stlouisfed.org/docs/api/api_key.html  (without it: public CSV download)
$env:EIA_API_KEY  = "..."   # https://www.eia.gov/opendata/register.php        (without it: regional diesel skipped)
python 03_Source_Data/fetch_external_data.py
```

Rerun it any time to refresh. Raw API responses are kept per day in `external_data/raw/` as the landing zone.
