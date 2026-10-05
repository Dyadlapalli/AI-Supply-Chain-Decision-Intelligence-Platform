"""
Run the data quality rules against the raw layer.

Steps:
  1. Deploy the rules in 04_Database/dq/rules.sql (one view per rule + rule catalogue)
  2. Load the generators' answer keys (dq_issue_log.csv) into dq.answer_key - a test fixture used only to
     measure how many planted defects the rules find; the pipeline itself never reads it
  3. Execute dq.usp_run_checks: every active rule runs, results go to dq.rule_result and dq.issue
  4. Print the scorecards

Usage:
    python 04_Database/run_dq.py
"""

import re
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from load_raw import REPO, SRC, connect, snake  # noqa: E402

RULES_SQL = Path(__file__).parent / "dq" / "rules.sql"


def deploy_rules(conn):
    batches = [b for b in re.split(r"(?im)^\s*GO\s*$", RULES_SQL.read_text(encoding="utf-8")) if b.strip()]
    cur = conn.cursor()
    for b in batches:
        cur.execute(b)
    return len(batches)


def answer_key() -> pd.DataFrame:
    frames = []
    for folder, prefix in (("master_data", "raw.master_"), ("erp_data", "raw.erp_")):
        path = SRC / folder / "dq_issue_log.csv"
        if path.exists():
            df = pd.read_csv(path, dtype=str, keep_default_na=False)
            # A planted "defect" that left the value unchanged (e.g. lower-casing an all-digit part number)
            # is not a defect at all - drop it so it does not count as a miss
            df = df[~((df["golden_value"] != "") & (df["golden_value"] == df["raw_value"]))]
            frames.append(pd.DataFrame({
                "source_table": prefix + df["table"],
                "record_key": df["record_key"].replace("", "(missing)"),
                "column_name": df["column"], "issue_type": df["issue_type"],
                "dq_dimension": df["dq_dimension"], "severity": df["severity"]}))

    path = SRC / "business_files" / "dq_issue_log.csv"
    if path.exists():
        df = pd.read_csv(path, dtype=str, keep_default_na=False)

        def table(f):
            return ("raw.sp_" if "Forecast_Overrides" in f else "raw.bf_") + snake(Path(f).stem)

        def key(sheet, loc):  # 'C47' or 'row 47' -> 'Sheet!47'; anything else is file/column level
            m = re.fullmatch(r"(?:[A-Z]+|row )(\d+)", loc)
            return f"{sheet}!{m.group(1)}" if m and sheet != "*" else "*"

        frames.append(pd.DataFrame({
            "source_table": df["file"].map(table),
            "record_key": [key(s, l) for s, l in zip(df["sheet"], df["location"])],
            "column_name": df["column"], "issue_type": df["issue_type"],
            "dq_dimension": df["dq_dimension"], "severity": df["severity"]}))
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def load_answer_key(conn, df):
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE dq.answer_key")
    if df.empty:
        return
    cur.fast_executemany = True
    cur.executemany("INSERT INTO dq.answer_key VALUES (?, ?, ?, ?, ?, ?)",
                    df[["source_table", "record_key", "column_name", "issue_type", "dq_dimension", "severity"]]
                    .values.tolist())


def show(conn, title, sql):
    cur = conn.execute(sql)
    cols = [d[0] for d in cur.description]
    rows = [[("" if v is None else str(v)) for v in r] for r in cur.fetchall()]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c) for i, c in enumerate(cols)]
    print(f"\n{title}")
    print("  " + "  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    for r in rows:
        print("  " + "  ".join(v.ljust(w) for v, w in zip(r, widths)))


def main():
    conn = connect(autocommit=True)
    n = deploy_rules(conn)
    print(f"Deployed rules.sql ({n} batches); "
          f"{conn.execute('SELECT COUNT(*) FROM dq.rule_catalog WHERE is_active = 1').fetchval()} active rules")

    key = answer_key()
    load_answer_key(conn, key)
    print(f"Loaded answer key: {len(key):,} planted defects")

    run_id = conn.execute("DECLARE @r INT; EXEC dq.usp_run_checks @run_id = @r OUTPUT; SELECT @r").fetchval()
    run = conn.execute("SELECT status, rules_run, issues_found, DATEDIFF(SECOND, started_at, finished_at) "
                       "FROM dq.run WHERE run_id = ?", run_id).fetchone()
    print(f"Run {run_id}: {run[0]}, {run[1]} rules, {run[2]:,} issues, {run[3]}s")

    errors = conn.execute("SELECT rule_id, error_message FROM dq.rule_result WHERE run_id = ? AND status = 'error'",
                          run_id).fetchall()
    for rule_id, msg in errors:
        print(f"  ! {rule_id}: {msg}")

    show(conn, "Data quality score by source table (share of records with no issue)",
         "SELECT source_table, records, records_with_issues AS with_issues, records_with_high_issues AS with_high, "
         "CAST(dq_score * 100 AS DECIMAL(5,1)) AS score_pct FROM dq.v_table_scorecard ORDER BY source_table")
    show(conn, "Issues by dimension and severity",
         "SELECT dq_dimension, severity, COUNT(*) AS issues FROM dq.v_issue GROUP BY dq_dimension, severity "
         "ORDER BY dq_dimension, severity")
    show(conn, "Detection vs. planted defects (record level)",
         "SELECT source_table, planted_defect_records AS planted, detected, flagged_records AS flagged, "
         "correctly_flagged AS correct, CAST(recall * 100 AS DECIMAL(5,1)) AS recall_pct, "
         "CAST(precision * 100 AS DECIMAL(5,1)) AS precision_pct FROM dq.v_detection_score ORDER BY source_table")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
