/*
    04_Database/clean/03_business.sql
    clean.usp_build_business: turns the planners' Excel and SharePoint files into clean tables.
    Run after clean.usp_build_master (uses its crosswalks and clean.part).

    The raw tables hold these files cell for cell, so this is where the spreadsheet LAYOUT is interpreted:
    title rows, merged branch cells, subtotal rows, meaning held in cell colour, free-text names, and two
    versions of the safety stock file (the FINAL file is the source of truth; v2 is superseded).
*/
CREATE OR ALTER PROCEDURE clean.usp_build_business
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM clean.quarantine WHERE source_table LIKE 'raw.bf[_]%' OR source_table LIKE 'raw.sp[_]%';

    /* =========================================================================================
       INVENTORY POLICY - crosstab (category x criticality x 4 metrics) -> one row per category x criticality
    ========================================================================================= */
    DROP TABLE IF EXISTS #cells;
    SELECT COALESCE(syn.approved_value, LTRIM(RTRIM(c.category))) AS part_category, c.criticality, c.metric, c.val,
           CASE
               WHEN c.metric = N'service_level' THEN
                   CASE WHEN c.val LIKE N'%[%]' THEN TRY_CAST(REPLACE(c.val, N'%', N'') AS DECIMAL(9, 4)) / 100     -- '95%'
                        WHEN TRY_CAST(c.val AS DECIMAL(9, 4)) > 1 THEN TRY_CAST(c.val AS DECIMAL(9, 4)) / 100       -- 93 -> 0.93
                        ELSE TRY_CAST(c.val AS DECIMAL(9, 4)) END
               WHEN c.val LIKE N'%wk%' THEN TRY_CAST(LEFT(c.val, PATINDEX(N'%[^0-9]%', c.val) - 1) AS INT) * 7   -- '2 wks' -> 14
               ELSE TRY_CAST(c.val AS DECIMAL(9, 4))
           END AS num
    INTO #cells
    FROM dq.v_bf_policy_cells AS c
    LEFT JOIN clean.ref_synonym AS syn ON syn.domain = 'part_category' AND syn.source_value = LTRIM(RTRIM(c.category));

    DROP TABLE IF EXISTS clean.inventory_policy;
    SELECT ISNULL(CAST(part_category AS NVARCHAR(40)), N'') AS part_category, ISNULL(CAST(criticality AS VARCHAR(10)), '') AS criticality,
           CAST(MAX(IIF(metric = N'service_level' AND num BETWEEN 0.5 AND 1, num, NULL)) AS DECIMAL(4, 3)) AS service_level_target,
           CAST(MAX(IIF(metric = N'review_days', num, NULL)) AS SMALLINT) AS review_cycle_days,
           CAST(MAX(IIF(metric = N'min_dos', num, NULL)) AS SMALLINT) AS min_days_of_supply,
           CAST(MAX(IIF(metric = N'max_dos', num, NULL)) AS SMALLINT) AS max_days_of_supply
    INTO clean.inventory_policy
    FROM #cells
    GROUP BY part_category, criticality;
    -- A minimum above its maximum: one of the two is wrong and the file cannot say which (B-IP-04)
    UPDATE clean.inventory_policy SET min_days_of_supply = NULL WHERE min_days_of_supply > max_days_of_supply;
    EXEC (N'ALTER TABLE clean.inventory_policy ADD CONSTRAINT PK_clean_inventory_policy PRIMARY KEY (part_category, criticality)');

    /* =========================================================================================
       SAFETY STOCK TARGETS - FINAL file only; branch carried down merged cells; subtotals skipped
    ========================================================================================= */
    DROP TABLE IF EXISTS #ss;
    SELECT r.record_key, r.sheet_name, r.excel_row, bx.branch_id, p.part_id, p.part_number,
           p.part_category, p.criticality,
           TRY_CAST(r.ss AS INT) AS ss, TRY_CAST(r.rop AS INT) AS rop, TRY_CAST(r.max_qty AS INT) AS max_qty,
           raw.c07 AS approved_by, r.comments,
           ROW_NUMBER() OVER (PARTITION BY bx.branch_id, p.part_id ORDER BY r.sheet_name, r.excel_row) AS copy_no
    INTO #ss
    FROM dq.v_bf_safety_stock_rows AS r
    JOIN raw.bf_safety_stock_targets_fy2026_final AS raw ON raw.sheet_name = r.sheet_name AND TRY_CAST(raw.excel_row AS INT) = r.excel_row
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = LTRIM(RTRIM(r.branch))
    LEFT JOIN clean.part AS p ON p.part_number = clean.fn_canon_part(r.part_number);

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.bf_safety_stock_targets_fy2026_final', record_key,
           IIF(part_id IS NULL, 'B-SS-06', 'CLEAN-06'),
           IIF(part_id IS NULL, N'Part number not in the part master', N'Branch name not recognised')
    FROM #ss WHERE part_id IS NULL OR branch_id IS NULL;

    DROP TABLE IF EXISTS clean.safety_stock_target;
    SELECT ISNULL(CAST(s.branch_id AS VARCHAR(10)), '') AS branch_id, ISNULL(CAST(s.part_id AS VARCHAR(10)), '') AS part_id,
           CAST(s.part_number AS VARCHAR(20)) AS part_number,
           IIF(s.ss > s.rop, NULL, s.ss) AS safety_stock_qty,          -- text, blank, or above ROP -> unknown (B-SS-01/02/03)
           s.rop AS reorder_point_qty,
           IIF(s.max_qty < s.rop, NULL, s.max_qty) AS max_qty,          -- below ROP -> unknown (B-SS-04)
           ip.service_level_target,
           CAST('2026-01-01' AS DATE) AS effective_date,               -- the file is the FY2026 target set
           CAST(LTRIM(RTRIM(s.approved_by)) AS NVARCHAR(60)) AS approved_by,
           CAST(s.comments AS NVARCHAR(200)) AS planner_comment,       -- manual overrides (B-SS-08)
           CAST(s.record_key AS NVARCHAR(60)) AS source_cell
    INTO clean.safety_stock_target
    FROM #ss AS s
    LEFT JOIN clean.inventory_policy AS ip ON ip.part_category = s.part_category AND ip.criticality = s.criticality
    WHERE s.part_id IS NOT NULL AND s.branch_id IS NOT NULL
      AND s.copy_no = 1;   -- the same part listed twice for a branch: the first entry stands (B-SS-07)
    EXEC (N'ALTER TABLE clean.safety_stock_target ADD CONSTRAINT PK_clean_safety_stock_target PRIMARY KEY (branch_id, part_id)');

    /* =========================================================================================
       SUPPLIER EXCEPTIONS - free-text supplier names matched to supplier IDs
    ========================================================================================= */
    DROP TABLE IF EXISTS clean.supplier_exception;
    SELECT ISNULL(CAST(N'SX' + RIGHT(N'0000' + CAST(TRY_CAST(r.excel_row AS INT) - 3 AS NVARCHAR(4)), 4) AS VARCHAR(10)), '') AS exception_id,
           CAST(sx.supplier_id AS VARCHAR(10)) AS supplier_id, s.supplier_name,
           CAST(r.c03 AS NVARCHAR(300)) AS issue, CAST(r.c04 AS NVARCHAR(40)) AS impacted_category,
           clean.fn_to_date(r.c05) AS start_date, clean.fn_to_date(r.c06) AS expected_resolution,
           CAST(r.c07 AS VARCHAR(10)) AS impact, CAST(st.approved_value AS VARCHAR(10)) AS status,
           CAST(r.c08 AS NVARCHAR(60)) AS owner
    INTO clean.supplier_exception
    FROM raw.bf_supplier_exception_list AS r
    OUTER APPLY (   -- name variants of every source record, including duplicates, resolve to the real supplier
        SELECT TOP (1) x.supplier_id FROM clean.supplier_xref x
        WHERE dq.fn_norm_name(x.source_supplier_name) = dq.fn_norm_name(r.c02)
        ORDER BY x.source_supplier_id
    ) AS sx
    LEFT JOIN clean.supplier AS s ON s.supplier_id = sx.supplier_id
    LEFT JOIN clean.ref_synonym AS st ON st.domain = 'status' AND st.source_value = LTRIM(RTRIM(r.c09))   -- case-insensitive
    WHERE TRY_CAST(r.excel_row AS INT) >= 4
      AND NOT EXISTS (SELECT 1 FROM dq.chk_B_SX_02 q WHERE q.record_key = r.sheet_name + N'!' + r.excel_row);
    EXEC (N'ALTER TABLE clean.supplier_exception ADD CONSTRAINT PK_clean_supplier_exception PRIMARY KEY (exception_id)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.bf_supplier_exception_list', record_key, 'B-SX-02', N'One row covers several suppliers; each already has its own row'
    FROM dq.chk_B_SX_02;

    /* =========================================================================================
       CRITICAL PARTS - priority read from the row's fill colour (red = P1); the file has no column for it
    ========================================================================================= */
    DROP TABLE IF EXISTS #cp;
    SELECT c.record_key, c.excel_row,
           p.part_id, p.part_number, p.part_description,
           -- free-text machine list 'CAT 980, 980B, others' -> the first machine named
           LTRIM(RTRIM(IIF(CHARINDEX(N',', c.machines) > 0, LEFT(c.machines, CHARINDEX(N',', c.machines) - 1), c.machines))) AS equipment_model,
           COALESCE(sc.approved_value, IIF(NULLIF(LTRIM(c.scope), N'') IS NULL, N'ALL', NULL)) AS scope,
           IIF(r.row_fill_color LIKE N'%FF9999', 'P1', 'P2') AS priority,
           r.c05 AS reason, r.c06 AS added_by, clean.fn_to_date(r.c07) AS added_date,
           ROW_NUMBER() OVER (PARTITION BY p.part_id ORDER BY c.excel_row) AS copy_no
    INTO #cp
    FROM dq.v_bf_critical_rows AS c
    JOIN raw.bf_critical_parts_list AS r ON r.sheet_name + N'!' + r.excel_row = c.record_key
    -- 'A / B' in one cell: the row is about the first part; the second has its own row
    CROSS APPLY (SELECT LTRIM(RTRIM(IIF(CHARINDEX(N'/', c.part_number) > 0, LEFT(c.part_number, CHARINDEX(N'/', c.part_number) - 1), c.part_number))) AS pn) AS first_part
    LEFT JOIN clean.part AS p ON p.part_number = clean.fn_canon_part(first_part.pn)
    LEFT JOIN clean.ref_synonym AS sc ON sc.domain = 'scope' AND sc.source_value = LTRIM(RTRIM(c.scope));

    DROP TABLE IF EXISTS clean.critical_part;
    SELECT ISNULL(CAST(part_id AS VARCHAR(10)), '') AS part_id, CAST(part_number AS VARCHAR(20)) AS part_number,
           CAST(part_description AS NVARCHAR(100)) AS part_description, CAST(equipment_model AS NVARCHAR(60)) AS equipment_model,
           CAST(scope AS VARCHAR(20)) AS scope, CAST(priority AS CHAR(2)) AS priority, CAST(reason AS NVARCHAR(200)) AS reason,
           CAST(added_by AS NVARCHAR(60)) AS added_by, added_date
    INTO clean.critical_part
    FROM #cp WHERE part_id IS NOT NULL AND copy_no = 1;   -- listed twice: first entry stands (B-CP-06)
    EXEC (N'ALTER TABLE clean.critical_part ADD CONSTRAINT PK_clean_critical_part PRIMARY KEY (part_id)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.bf_critical_parts_list', record_key, 'CLEAN-07', N'Part number not in the part master'
    FROM #cp WHERE part_id IS NULL;

    /* =========================================================================================
       FORECAST OVERRIDES (SharePoint export)
    ========================================================================================= */
    DROP TABLE IF EXISTS #fo;
    SELECT o.record_key, TRY_CAST(o.id AS INT) AS override_id,
           bx.branch_id, o.scope_type, o.scope, o.adjustment_pct, o.reason,
           clean.fn_to_date(LEFT(o.created, 10)) AS submitted_date,
           o.forecast_month, clean.fn_to_date(o.forecast_month) AS month_parsed,
           ap.approved_value AS approval_status, NULLIF(o.approver, N'') AS approved_by,
           -- claims login 'i:0#.f|membership|dcarterlee@...' -> person, via the display names used as approvers
           (SELECT TOP (1) a.approver FROM raw.sp_forecast_overrides_export a
            WHERE LOWER(REPLACE(REPLACE(REPLACE(a.approver, N'. ', N''), N'-', N''), N' ', N''))
                  = SUBSTRING(o.created_by, CHARINDEX(N'membership|', o.created_by) + 11,
                              CHARINDEX(N'@', o.created_by) - CHARINDEX(N'membership|', o.created_by) - 11)) AS submitted_by,
           ROW_NUMBER() OVER (PARTITION BY o.branch, o.scope_type, o.scope, o.forecast_month, o.title ORDER BY TRY_CAST(o.id AS INT)) AS copy_no
    INTO #fo
    FROM dq.v_sp_overrides AS o
    -- 'Richmond;#4' -> 'Richmond' (the number is the SharePoint list item, not the branch ID)
    LEFT JOIN clean.branch_xref AS bx ON bx.source_value = LEFT(o.branch, CHARINDEX(N';#', o.branch + N';#') - 1)
    LEFT JOIN clean.ref_synonym AS ap ON ap.domain = 'approval' AND ap.source_value = o.approval_status;

    DROP TABLE IF EXISTS clean.forecast_override;
    SELECT ISNULL(f.override_id, 0) AS override_id, CAST(f.branch_id AS VARCHAR(10)) AS branch_id,
           CAST(f.scope_type AS VARCHAR(30)) AS scope_level, CAST(f.scope AS NVARCHAR(60)) AS scope_value,
           -- 'August' with no year: the first August on or after the date it was submitted
           COALESCE(f.month_parsed, m.month_start) AS forecast_month,
           CAST(f.adjustment_pct AS DECIMAL(6, 2)) AS adjustment_pct, CAST(f.reason AS NVARCHAR(200)) AS reason,
           CAST(f.submitted_by AS NVARCHAR(60)) AS submitted_by, f.submitted_date,
           CAST(f.approval_status AS VARCHAR(10)) AS approval_status, CAST(f.approved_by AS NVARCHAR(60)) AS approved_by
    INTO clean.forecast_override
    FROM #fo AS f
    OUTER APPLY (
        SELECT MIN(d) AS month_start
        FROM (VALUES (TRY_CONVERT(DATE, N'01 ' + f.forecast_month + N' ' + CAST(YEAR(f.submitted_date) AS NVARCHAR(4)), 106)),
                     (TRY_CONVERT(DATE, N'01 ' + f.forecast_month + N' ' + CAST(YEAR(f.submitted_date) + 1 AS NVARCHAR(4)), 106))) AS v (d)
        WHERE d >= DATEFROMPARTS(YEAR(f.submitted_date), MONTH(f.submitted_date), 1)
    ) AS m
    WHERE f.copy_no = 1                         -- submitted again (S-FO-03)
      AND f.branch_id IS NOT NULL               -- no branch (S-FO-01)
      AND ABS(f.adjustment_pct) <= 100;         -- 400% is a typo for 40% or 4%; the list cannot say which (S-FO-02)
    EXEC (N'ALTER TABLE clean.forecast_override ADD CONSTRAINT PK_clean_forecast_override PRIMARY KEY (override_id)');

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.sp_forecast_overrides_export', f.record_key,
           CASE WHEN f.copy_no > 1 THEN 'S-FO-03' WHEN f.branch_id IS NULL THEN 'S-FO-01' ELSE 'S-FO-02' END,
           CASE WHEN f.copy_no > 1 THEN N'Override submitted more than once'
                WHEN f.branch_id IS NULL THEN N'Override has no branch'
                ELSE N'Adjustment over 100% - likely a typo, needs the planner to confirm' END
    FROM #fo AS f
    WHERE NOT EXISTS (SELECT 1 FROM clean.forecast_override c WHERE c.override_id = f.override_id);
END
GO
