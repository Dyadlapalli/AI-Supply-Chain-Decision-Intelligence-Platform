# Database

SQL Server scripts for the platform database `SupplyChainDI`. The design is documented in [2.3 Data_Model_Design.md](../02_Architecture/2.3%20Data_Model_Design.md).

## Contents

| Script | Creates |
|---|---|
| `sql/00_create_database.sql` | The `SupplyChainDI` database (local SQL Server only) |
| `sql/01_create_schemas.sql` | Layers: `raw`, `clean`, `mart`, `dq`, `audit` |
| `sql/02_mart_dimensions.sql` | 11 dimensions, including the generated calendar (2018–2027) and Unknown members |
| `sql/03_mart_facts.sql` | 12 fact tables with foreign keys and columnstore indexes |
| `sql/04_audit_tables.sql` | `audit.load_log` and the latest-load view (never dropped, keeps load history) |
| `sql/05_dq_framework.sql` | Data quality framework: rule catalogue, run history, issue register, scorecard views |
| `dq/rules.sql` | 119 data quality rules, one view per rule (deployed by `run_dq.py`) |
| `sql/06_agent_security.sql` | Read-only `dq_agent_reader` user for the AI agents |
| `sql/07_clean_framework.sql` | Clean layer helpers: date/money/part-number parsing, Data Steward reference data and synonyms, quarantine table |
| `clean/01_master.sql` | Builds clean master data and crosswalks (source ID -> surviving ID) |
| `clean/02_erp.sql` | Builds clean ERP transactions, repairing damaged values from related documents |
| `deploy.ps1` | Runs all scripts in order. Safe to rerun: it rebuilds the `mart` tables |
| `load_raw.py` | Loads every source file into the `raw` layer and records each load in `audit.load_log` |
| `run_dq.py` | Deploys and runs the data quality rules, prints scorecards |
| `run_clean.py` | Builds the clean layer and scores its accuracy against the golden files |

## Deploy

```powershell
.\04_Database\deploy.ps1
```

On Azure SQL Database, create the database in the portal, then run the scripts from `01_` onward.

## Load source data into `raw`

```powershell
pip install -r requirements.txt
python 04_Database/load_raw.py                  # all sources (~40 seconds)
python 04_Database/load_raw.py --source erp     # or: master, business, external
```

How the raw layer works:

- **Exactly as received.** Every value is stored as text; nothing is cleaned or dropped. Messy values like `18 days` or `Richmond;#4` are preserved for the clean layer to handle.
- **Excel files are copied cell for cell.** Business workbooks keep their layout (sheet name, Excel row number, every cell as `c01`..`cNN`) plus each row's fill colour, because colour carries meaning (red = P1 critical part) and merged cells or subtotal formulas (`=SUM(...)`) must be recognised, not lost.
- **Schema drift is detected.** If a file gains or loses columns, the table is extended and the load is logged as `warning` with the details.
- **All-or-nothing loads.** Each file replaces its table inside a transaction. If anything fails, the previous data stays in place and the failure is logged.
- **Full audit trail.** Every row has `_load_id`, `_source_file`, `_row_number`, `_loaded_at`. Every load is recorded in `audit.load_log` with row counts and the file's SHA-256 hash.

Check the latest loads in SSMS:

```sql
SELECT dataset, status, rows_loaded, note, finished_at FROM audit.v_latest_load ORDER BY dataset;
```

## Run data quality checks

```powershell
python 04_Database/run_dq.py
```

Runs all 119 rules against the `raw` layer (~25 seconds) and prints the data quality score per table and how many of the generators' planted defects were found. Design and results: [2.5 Data_Quality_Rules_and_Results.md](../02_Architecture/2.5%20Data_Quality_Rules_and_Results.md).

## Build the clean layer

```powershell
python 04_Database/run_dq.py       # the clean layer uses the rules' findings
python 04_Database/run_clean.py
```

Accuracy (share of cells matching the governed reference), raw vs. clean:

| Table | Raw | Clean | | Table | Raw | Clean |
|---|---|---|---|---|---|---|
| Branch | 75.0% | 100.0% | | Sales order lines | 99.7% | 100.0% |
| Product family | 86.0% | 98.0% | | Demand | 99.9% | 100.0% |
| Product category | 90.0% | 100.0% | | Purchase order lines | 99.8% | 99.9% |
| Product | 95.4% | 100.0% | | Goods receipts | 99.8% | 100.0% |
| Supplier | 93.5% | 98.5% | | Inventory transactions | 99.8% | 99.9% |
| Part | 97.0% | 99.8% | | | | |
| Equipment | 97.6% | 98.6% | | | | |

How values are repaired, in order of preference: standardize the format (dates, part numbers, names), apply the Data Steward's approved values and synonyms, take the value from a duplicate of the same record, infer it from related data (a part's unit cost from its latest purchase order, a supplier's lead time from its promised dates). A value that cannot be repaired is left NULL and stays flagged; it is never guessed. Design and results: [2.6 Clean_Layer.md](../02_Architecture/2.6%20Clean_Layer.md).

## Connecting (SSMS, Power BI, Python)

Use server name **`np:localhost`** with Windows Authentication, and tick **Trust server certificate**.

On this domain-joined laptop, Windows Authentication over the default local connection fails with *"The login is from an untrusted domain"*. The `np:` prefix connects over named pipes, which authenticates correctly. TCP/IP is disabled by default on SQL Server Developer Edition.
