"""
Load every source file into the `raw` layer of the SupplyChainDI database, exactly as received.

Raw layer rules (see 02_Architecture/2.3 Data_Model_Design.md):
  - Every value is stored as text. Nothing is cleaned, converted, or dropped.
  - Each table is created from the file's own header (schema-on-read landing). If a later file has new
    or missing columns, the table is extended and the drift is recorded in the load log.
  - Each load fully replaces the table's previous contents inside a transaction: a failed load leaves
    the previous data untouched.
  - Every row carries load metadata (_load_id, _source_file, _row_number, _loaded_at).
  - Every load is recorded in audit.load_log with row counts, the file's SHA-256, and the outcome.

Excel workbooks from the business are loaded cell-for-cell (one row per spreadsheet row, columns c01..cNN,
plus sheet name, Excel row number, and the row's fill colour) because their layout - title rows, merged
cells, colour-coded priority - is itself information the clean layer has to interpret.

Connection (environment variables, all optional):
    SQL_SERVER      default np:localhost   (named pipes; see 04_Database/README.md)
    SQL_DATABASE    default SupplyChainDI
    SQL_USER / SQL_PASSWORD   use SQL authentication instead of Windows authentication (e.g. Azure SQL)

Usage:
    python 04_Database/load_raw.py                    # all sources
    python 04_Database/load_raw.py --source erp       # one source: master, erp, business, external
"""

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timezone
from pathlib import Path

import pandas as pd
import pyodbc
from openpyxl import load_workbook

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "03_Source_Data"
CHUNK = 10_000
TEXT_LIMIT = 4000  # NVARCHAR(4000) unless a value is longer


@dataclass
class Source:
    system: str      # recorded in the load log
    group: str       # --source filter
    folder: Path
    pattern: str
    reader: str      # csv | excel_grid | excel_table
    prefix: str      # raw table name prefix
    missing_hint: str = ""


SOURCES = [
    Source("Master Data", "master", SRC / "master_data" / "raw", "*.csv", "csv", "master_"),
    Source("ERP", "erp", SRC / "erp_data" / "raw", "*.csv", "csv", "erp_",
           "full ERP extracts are git-ignored - run 03_Source_Data/generate_erp_data.py"),
    Source("Business Files", "business", SRC / "business_files" / "raw" / "excel", "*.xlsx", "excel_grid", "bf_"),
    Source("SharePoint", "business", SRC / "business_files" / "raw" / "sharepoint", "*.xlsx", "excel_table", "sp_"),
    Source("External", "external", SRC / "external_data", "*.csv", "csv", "ext_",
           "run 03_Source_Data/fetch_external_data.py"),
]


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

def connect(autocommit: bool) -> pyodbc.Connection:
    server = os.environ.get("SQL_SERVER", "np:localhost")
    database = os.environ.get("SQL_DATABASE", "SupplyChainDI")
    cs = f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={server};DATABASE={database};TrustServerCertificate=yes;"
    if os.environ.get("SQL_USER"):
        cs += f"UID={os.environ['SQL_USER']};PWD={os.environ.get('SQL_PASSWORD', '')};"
    else:
        cs += "Trusted_Connection=yes;"
    return pyodbc.connect(cs, autocommit=autocommit)


# ---------------------------------------------------------------------------
# Readers - every value becomes str or None
# ---------------------------------------------------------------------------

def as_text(v) -> str | None:
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    if isinstance(v, (datetime, date, time)):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    s = str(v)
    return s if s != "" else None


def read_csv(path: Path) -> tuple[list[str], list[list]]:
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[], encoding="utf-8")
    rows = df.astype(object).where(df != "", None).values.tolist()
    return list(df.columns), rows


def read_excel_table(path: Path) -> tuple[list[str], list[list]]:
    """A workbook that is already a single table with a header row (e.g. a SharePoint list export)."""
    ws = load_workbook(path, data_only=False).worksheets[0]
    it = ws.iter_rows(values_only=True)
    header = [as_text(h) or f"column_{i + 1}" for i, h in enumerate(next(it))]
    rows = [[as_text(v) for v in r] for r in it if any(v is not None for v in r)]
    return header, rows


def read_excel_grid(path: Path) -> tuple[list[str], list[list]]:
    """Cell-for-cell copy of every sheet, keeping the layout the business built."""
    wb = load_workbook(path, data_only=False)  # formulas are kept as text, e.g. =SUM(C5:C9)
    width = max(ws.max_column for ws in wb.worksheets)
    header = ["sheet_name", "excel_row", "row_fill_color"] + [f"c{i:02d}" for i in range(1, width + 1)]
    rows = []
    for ws in wb.worksheets:
        for r in ws.iter_rows(min_row=1, max_row=ws.max_row, max_col=width):
            values = [as_text(c.value) for c in r]
            if not any(values):
                continue
            first = r[0]
            fill = first.fill.fgColor.rgb if first.fill and first.fill.fill_type == "solid" else None
            rows.append([ws.title, str(first.row), fill if isinstance(fill, str) else None] + values)
    return header, rows


READERS = {"csv": read_csv, "excel_table": read_excel_table, "excel_grid": read_excel_grid}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def snake(name: str) -> str:
    s = re.sub(r"[^0-9a-zA-Z]+", "_", str(name)).strip("_").lower()
    return f"c_{s}" if not s or s[0].isdigit() else s


def unique_columns(names: list[str]) -> list[str]:
    seen, out = {}, []
    for n in (snake(x) for x in names):
        if n.startswith("_"):
            n = "src" + n
        seen[n] = seen.get(n, 0) + 1
        out.append(n if seen[n] == 1 else f"{n}_{seen[n]}")
    return out


def q(identifier: str) -> str:
    return "[" + identifier.replace("]", "]]") + "]"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


# ---------------------------------------------------------------------------
# Loader
# ---------------------------------------------------------------------------

class Loader:
    def __init__(self):
        self.batch_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.audit = connect(autocommit=True)   # separate connection: log rows survive a rolled-back load
        self.data = connect(autocommit=False)
        self.results = []
        self.seq = 0  # makes load_id unique even if a dataset is loaded twice in one batch

    def log_start(self, load_id, src: Source, dataset, table, rel, file_hash, modified):
        self.audit.execute(
            "INSERT INTO audit.load_log (load_id, batch_id, source_system, dataset, target_table, source_file, "
            "file_sha256, file_modified_at, status, started_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'running', ?)",
            load_id, self.batch_id, src.system, dataset, f"raw.{table}", rel, file_hash, modified, utcnow())

    def log_end(self, load_id, status, rows_read=None, rows_loaded=None, note=None, columns=None):
        self.audit.execute(
            "UPDATE audit.load_log SET status = ?, rows_read = ?, rows_loaded = ?, note = ?, finished_at = ?, "
            "source_columns = COALESCE(?, source_columns) WHERE load_id = ?",
            status, rows_read, rows_loaded, (note or "")[:1000] or None, utcnow(),
            json.dumps(columns) if columns else None, load_id)

    def ensure_table(self, table, columns, rows) -> list[str]:
        """Create the raw table, or extend it if the file brought new columns. Returns drift notes."""
        cur = self.data.cursor()
        widths = [max((len(r[i]) for r in rows if r[i] is not None), default=0) for i in range(len(columns))]
        col_type = {c: ("NVARCHAR(MAX)" if w > TEXT_LIMIT else f"NVARCHAR({TEXT_LIMIT})")
                    for c, w in zip(columns, widths)}
        info = {r.COLUMN_NAME: r.CHARACTER_MAXIMUM_LENGTH for r in cur.execute(
            "SELECT COLUMN_NAME, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS "
            "WHERE TABLE_SCHEMA = 'raw' AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION", table)}
        existing = list(info)
        if not existing:
            cols_sql = ",\n    ".join(f"{q(c)} {col_type[c]} NULL" for c in columns)
            cur.execute(f"""CREATE TABLE raw.{q(table)} (
    _load_id     VARCHAR(60)    NOT NULL,
    _source_file NVARCHAR(400)  NOT NULL,
    _row_number  INT            NOT NULL,
    _loaded_at   DATETIME2(0)   NOT NULL,
    {cols_sql}
)""")
            return []
        notes = []
        added = [c for c in columns if c not in existing]
        for c in added:
            cur.execute(f"ALTER TABLE raw.{q(table)} ADD {q(c)} {col_type[c]} NULL")
        if added:
            notes.append(f"schema drift - new columns added: {', '.join(added)}")
        widened = [c for c in columns if c in info and info[c] != -1 and col_type[c] == "NVARCHAR(MAX)"]
        for c in widened:  # -1 = already MAX
            cur.execute(f"ALTER TABLE raw.{q(table)} ALTER COLUMN {q(c)} NVARCHAR(MAX) NULL")
        if widened:
            notes.append(f"columns widened to NVARCHAR(MAX): {', '.join(widened)}")
        missing = [c for c in existing if not c.startswith("_") and c not in columns]
        if missing:
            notes.append(f"schema drift - columns missing from file: {', '.join(missing)}")
        return notes

    def load_file(self, src: Source, path: Path):
        dataset = src.prefix + snake(path.stem)
        table = dataset
        rel = path.relative_to(REPO).as_posix()
        self.seq += 1
        load_id = f"{self.batch_id}-{self.seq:03d}-{dataset}"[:60]
        started = utcnow()
        header = None
        # Logged before reading, so even an unreadable file leaves a 'failed' record
        self.log_start(load_id, src, dataset, table, rel, sha256(path),
                       datetime.fromtimestamp(path.stat().st_mtime).replace(microsecond=0))
        try:
            header, rows = READERS[src.reader](path)
            columns = unique_columns(header)
            # Pad / trim ragged rows to the header width
            n = len(columns)
            rows = [(r + [None] * n)[:n] for r in rows]
            notes = self.ensure_table(table, columns, rows)

            cur = self.data.cursor()
            cur.fast_executemany = True
            cur.execute(f"TRUNCATE TABLE raw.{q(table)}")
            insert = (f"INSERT INTO raw.{q(table)} (_load_id, _source_file, _row_number, _loaded_at, "
                      f"{', '.join(q(c) for c in columns)}) VALUES ({', '.join(['?'] * (n + 4))})")
            for start in range(0, len(rows), CHUNK):
                batch = [[load_id, rel, start + i + 1, started] + r
                         for i, r in enumerate(rows[start:start + CHUNK])]
                cur.executemany(insert, batch)
            loaded = cur.execute(f"SELECT COUNT(*) FROM raw.{q(table)} WHERE _load_id = ?", load_id).fetchval()
            if loaded != len(rows):
                raise RuntimeError(f"row count mismatch: read {len(rows)}, loaded {loaded}")
            self.data.commit()
            status = "warning" if notes else "ok"
            self.log_end(load_id, status, len(rows), loaded, "; ".join(notes), header)
            self.results.append((src.system, table, len(rows), status, "; ".join(notes)))
        except Exception as e:
            self.data.rollback()  # previous contents of the raw table stay in place
            msg = f"{type(e).__name__}: {e}"
            self.log_end(load_id, "failed", note=msg, columns=header)
            self.results.append((src.system, table, 0, "failed", msg[:120]))

    def skip(self, src: Source, note: str):
        self.seq += 1
        load_id = f"{self.batch_id}-{self.seq:03d}-{src.prefix}missing"[:60]
        self.audit.execute(
            "INSERT INTO audit.load_log (load_id, batch_id, source_system, dataset, target_table, source_file, "
            "status, note, started_at, finished_at) VALUES (?, ?, ?, ?, '-', ?, 'skipped', ?, ?, ?)",
            load_id, self.batch_id, src.system, f"{src.prefix}*", src.folder.relative_to(REPO).as_posix(),
            note, utcnow(), utcnow())
        self.results.append((src.system, f"{src.prefix}*", 0, "skipped", note))

    def run(self, groups: set[str]):
        for src in SOURCES:
            if src.group not in groups:
                continue
            files = sorted(src.folder.glob(src.pattern)) if src.folder.exists() else []
            if not files:
                self.skip(src, f"no files in {src.folder.relative_to(REPO).as_posix()}"
                          + (f" - {src.missing_hint}" if src.missing_hint else ""))
                continue
            for path in files:
                print(f"  loading {path.relative_to(REPO).as_posix()} ...", flush=True)
                self.load_file(src, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", choices=["all", "master", "erp", "business", "external"], default="all")
    args = parser.parse_args()
    groups = {"master", "erp", "business", "external"} if args.source == "all" else {args.source}

    loader = Loader()
    print(f"Batch {loader.batch_id}")
    loader.run(groups)

    print(f"\n{'source':<16}{'raw table':<44}{'rows':>9}  status")
    for system, table, rows, status, note in loader.results:
        print(f"{system:<16}{table:<44}{rows:>9,}  {status}" + (f"  ({note})" if note else ""))
    failed = sum(r[3] == "failed" for r in loader.results)
    print(f"\n{len(loader.results)} datasets, {sum(r[2] for r in loader.results):,} rows, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
