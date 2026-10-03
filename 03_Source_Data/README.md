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

Source data is synthetic, generated to simulate a Caterpillar dealer's parts operation across 28 branches (VA, WV, MD, DE) from January 2023 to September 2026.

Each data set comes in two versions:

- **raw/** – messy data as it would arrive from source systems (duplicates, missing values, invalid references, inconsistent formats). This is the platform's input.
- **golden/** – the same data clean. Used only to validate data quality and cleansing results.
- **dq_issue_log.csv** – answer key listing every defect injected into raw/, tagged by data quality dimension (Completeness, Validity, Consistency, Uniqueness, Integrity) and severity.

| Folder | Contents | In Git |
|---|---|---|
| master_data/ | Branch, product family, product category, product, equipment, supplier, and part master (CSV + Excel) | Yes |
| erp_data/ | Sales orders, demand transactions, purchase orders, goods receipts, inventory transactions | Sample only |

### Rebuilding the data

Full ERP extracts (~100 MB) are not committed. A 1,000-row sample of each file is in `erp_data/sample/`. To regenerate everything:

```bash
pip install pandas numpy openpyxl
python 03_Source_Data/generate_master_data.py   # run first - ERP data is built on master data
python 03_Source_Data/generate_erp_data.py
```

Both scripts are deterministic (`--seed`, default 42) and accept `--scale` to change volume.
