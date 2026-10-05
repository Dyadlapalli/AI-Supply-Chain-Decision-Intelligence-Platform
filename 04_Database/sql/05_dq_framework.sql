/*
    05_dq_framework.sql
    Data quality framework: rule catalogue, run history, issue register, helper functions, and the runner.
    The rules themselves live in 04_Database/dq/rules.sql (one view per rule) and are deployed by run_dq.py,
    because they reference raw tables that only exist after the first load.

    Each rule is a view named dq.chk_<rule_id> returning the records that FAIL it:
        record_key   - business key of the failing record (same format as the source system)
        failed_value - the offending value(s), for the Data Steward
        related_key  - for duplicates: the key of the record this one duplicates
*/

/* ---------------------------------------------------------------------------------------------
   Tables (never dropped: run history must survive redeploys)
--------------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'dq.rule_catalog') IS NULL
CREATE TABLE dq.rule_catalog (
    rule_id         VARCHAR(20)    NOT NULL CONSTRAINT PK_dq_rule PRIMARY KEY,
    rule_name       NVARCHAR(150)  NOT NULL,
    source_system   VARCHAR(30)    NOT NULL,
    source_table    VARCHAR(128)   NOT NULL,   -- raw.<table>
    column_name     VARCHAR(128)   NULL,
    dq_dimension    VARCHAR(15)    NOT NULL
        CONSTRAINT CK_dq_rule_dimension CHECK (dq_dimension IN ('Completeness', 'Validity', 'Consistency', 'Uniqueness', 'Integrity')),
    severity        VARCHAR(10)    NOT NULL CONSTRAINT CK_dq_rule_severity CHECK (severity IN ('High', 'Medium', 'Low')),
    action          VARCHAR(10)    NOT NULL CONSTRAINT CK_dq_rule_action CHECK (action IN ('quarantine', 'fix', 'flag')),
    description     NVARCHAR(500)  NULL,
    is_active       BIT            NOT NULL CONSTRAINT DF_dq_rule_active DEFAULT 1
);

IF OBJECT_ID(N'dq.run') IS NULL
CREATE TABLE dq.run (
    run_id          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_dq_run PRIMARY KEY,
    started_at      DATETIME2(0)   NOT NULL,
    finished_at     DATETIME2(0)   NULL,
    status          VARCHAR(10)    NOT NULL,   -- running / ok / warning (some rules errored)
    rules_run       INT            NULL,
    issues_found    INT            NULL
);

IF OBJECT_ID(N'dq.rule_result') IS NULL
CREATE TABLE dq.rule_result (
    run_id              INT            NOT NULL,
    rule_id             VARCHAR(20)    NOT NULL,
    records_evaluated   INT            NULL,
    records_failed      INT            NULL,
    duration_ms         INT            NULL,
    status              VARCHAR(10)    NOT NULL,   -- ok / error
    error_message       NVARCHAR(1000) NULL,
    CONSTRAINT PK_dq_rule_result PRIMARY KEY (run_id, rule_id)
);

IF OBJECT_ID(N'dq.issue') IS NULL
BEGIN
    CREATE TABLE dq.issue (
        run_id          INT            NOT NULL,
        rule_id         VARCHAR(20)    NOT NULL,
        record_key      NVARCHAR(200)  NOT NULL,
        failed_value    NVARCHAR(400)  NULL,
        related_key     NVARCHAR(200)  NULL
    );
    CREATE CLUSTERED INDEX CIX_dq_issue ON dq.issue (run_id, rule_id);
END

-- Answer key from the data generators (test fixture used only to score the rules, never by the pipeline)
IF OBJECT_ID(N'dq.answer_key') IS NULL
CREATE TABLE dq.answer_key (
    source_table    VARCHAR(128)   NOT NULL,   -- raw.<table>
    record_key      NVARCHAR(200)  NOT NULL,
    column_name     VARCHAR(128)   NULL,
    issue_type      NVARCHAR(200)  NULL,
    dq_dimension    VARCHAR(15)    NULL,
    severity        VARCHAR(10)    NULL
);
GO

/* ---------------------------------------------------------------------------------------------
   Helper functions
--------------------------------------------------------------------------------------------- */

-- Normalizes an organization name for matching: upper case, no punctuation or legal suffixes,
-- common abbreviations expanded. 'Cat Parts Dist Ctr - Atlanta' -> 'CATERPILLAR PARTS DISTRIBUTION CENTER ATLANTA'
CREATE OR ALTER FUNCTION dq.fn_norm_name (@s NVARCHAR(400))
RETURNS NVARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
    IF @s IS NULL RETURN NULL;
    DECLARE @t NVARCHAR(400) = N' ' + UPPER(@s) + N' ';
    SET @t = TRANSLATE(@t, N'.,;:''"()-/', N'          ');
    SET @t = REPLACE(@t, N'&', N' AND ');
    SET @t = REPLACE(@t, N' CAT ', N' CATERPILLAR ');
    SET @t = REPLACE(@t, N' DIST ', N' DISTRIBUTION ');
    SET @t = REPLACE(@t, N' CTR ', N' CENTER ');
    SET @t = REPLACE(@t, N' SYS ', N' SYSTEMS ');
    WHILE CHARINDEX(N'  ', @t) > 0 SET @t = REPLACE(@t, N'  ', N' ');
    SET @t = REPLACE(@t, N' INC ', N' ');
    SET @t = REPLACE(@t, N' LLC ', N' ');
    SET @t = REPLACE(@t, N' CO ', N' ');
    SET @t = REPLACE(@t, N' COMPANY ', N' ');
    SET @t = REPLACE(@t, N' CORPORATION ', N' ');
    RETURN LTRIM(RTRIM(@t));
END
GO

-- Normalizes a part number for matching: '1r 0750 ' / '1R0750' / '01R-0750' -> '1R0750'
-- (Caterpillar part numbers never start with 0, so leading zeros are padding)
CREATE OR ALTER FUNCTION dq.fn_norm_part (@s NVARCHAR(100))
RETURNS NVARCHAR(100)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @t NVARCHAR(100) = UPPER(REPLACE(REPLACE(LTRIM(RTRIM(@s)), N'-', N''), N' ', N''));
    RETURN SUBSTRING(@t, PATINDEX(N'%[^0]%', @t + N'.'), 100);
END
GO

-- 1 if the value is a valid Caterpillar-format part number: 1R-0750 or 326-1644 (upper case, no padding).
-- Binary collation: in a case-sensitive collation the range [A-Z] still matches lower case b-z.
CREATE OR ALTER FUNCTION dq.fn_is_part_number (@s NVARCHAR(100))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @s IS NULL OR DATALENGTH(@s) <> LEN(@s) * 2 RETURN 0;  -- LIKE ignores trailing spaces, so check length
    IF @s COLLATE Latin1_General_BIN2 LIKE N'[1-9][A-Z]-[0-9][0-9][0-9][0-9]'
       OR @s COLLATE Latin1_General_BIN2 LIKE N'[1-9][0-9][0-9]-[0-9][0-9][0-9][0-9]'
        RETURN 1;
    RETURN 0;
END
GO

-- 1 if the value is an ISO date (YYYY-MM-DD, optionally followed by a time) that converts
CREATE OR ALTER FUNCTION dq.fn_is_iso_date (@s NVARCHAR(100))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @s LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%' AND TRY_CONVERT(DATE, LEFT(@s, 10), 23) IS NOT NULL
        RETURN 1;
    RETURN 0;
END
GO

-- 1 if the value has leading or trailing spaces (invisible to = comparisons in SQL Server)
CREATE OR ALTER FUNCTION dq.fn_has_padding (@s NVARCHAR(4000))
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @s IS NOT NULL AND (DATALENGTH(@s) <> LEN(@s) * 2 OR LEFT(@s, 1) = N' ') RETURN 1;
    RETURN 0;
END
GO

/* ---------------------------------------------------------------------------------------------
   Runner: executes every active rule, records results and issues
--------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dq.usp_run_checks
    @run_id INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dq.run (started_at, status) VALUES (SYSUTCDATETIME(), 'running');
    SET @run_id = SCOPE_IDENTITY();

    DECLARE @rule_id VARCHAR(20), @source_table VARCHAR(128), @sql NVARCHAR(MAX),
            @evaluated INT, @failed INT, @t0 DATETIME2(3), @errors INT = 0;

    DECLARE rules CURSOR LOCAL FAST_FORWARD FOR
        SELECT rule_id, source_table FROM dq.rule_catalog WHERE is_active = 1 ORDER BY rule_id;
    OPEN rules;
    FETCH NEXT FROM rules INTO @rule_id, @source_table;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @t0 = SYSUTCDATETIME();
        BEGIN TRY
            SET @sql = N'SELECT @n = COUNT(*) FROM ' + @source_table;
            EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @evaluated OUTPUT;

            SET @sql = N'INSERT INTO dq.issue (run_id, rule_id, record_key, failed_value, related_key)
                         SELECT @run, @rule, COALESCE(record_key, N''(missing)''), LEFT(failed_value, 400), related_key
                         FROM dq.' + QUOTENAME(N'chk_' + REPLACE(@rule_id, '-', '_')) + N';';
            EXEC sp_executesql @sql, N'@run INT, @rule VARCHAR(20)', @run = @run_id, @rule = @rule_id;
            SET @failed = @@ROWCOUNT;

            INSERT INTO dq.rule_result VALUES (@run_id, @rule_id, @evaluated, @failed,
                                               DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME()), 'ok', NULL);
        END TRY
        BEGIN CATCH
            SET @errors += 1;
            INSERT INTO dq.rule_result VALUES (@run_id, @rule_id, @evaluated, NULL,
                                               DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME()), 'error', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM rules INTO @rule_id, @source_table;
    END
    CLOSE rules;
    DEALLOCATE rules;

    UPDATE dq.run
    SET finished_at = SYSUTCDATETIME(),
        status = IIF(@errors > 0, 'warning', 'ok'),
        rules_run = (SELECT COUNT(*) FROM dq.rule_result WHERE run_id = @run_id),
        issues_found = (SELECT COUNT(*) FROM dq.issue WHERE run_id = @run_id)
    WHERE run_id = @run_id;
END
GO

/* ---------------------------------------------------------------------------------------------
   Reporting views (latest run)
--------------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dq.v_latest_run AS
SELECT TOP (1) * FROM dq.run WHERE status <> 'running' ORDER BY run_id DESC;
GO

-- Every issue from the latest run, with its rule
CREATE OR ALTER VIEW dq.v_issue AS
SELECT r.rule_id, r.rule_name, r.source_system, r.source_table, r.column_name, r.dq_dimension, r.severity, r.action,
       i.record_key, i.failed_value, i.related_key, i.run_id
FROM dq.issue AS i
JOIN dq.rule_catalog AS r ON r.rule_id = i.rule_id
WHERE i.run_id = (SELECT run_id FROM dq.v_latest_run);
GO

-- One row per rule: how many records it checked and how many failed
CREATE OR ALTER VIEW dq.v_rule_scorecard AS
SELECT r.rule_id, r.rule_name, r.source_system, r.source_table, r.dq_dimension, r.severity, r.action,
       rr.records_evaluated, rr.records_failed,
       CAST(1.0 - 1.0 * rr.records_failed / NULLIF(rr.records_evaluated, 0) AS DECIMAL(6, 4)) AS pass_rate,
       rr.status, rr.error_message
FROM dq.rule_catalog AS r
JOIN dq.rule_result AS rr ON rr.rule_id = r.rule_id
WHERE rr.run_id = (SELECT run_id FROM dq.v_latest_run);
GO

-- One row per source table: share of records with no issue at all (DQ-01 by table)
CREATE OR ALTER VIEW dq.v_table_scorecard AS
WITH recs AS (
    SELECT source_table, MAX(records_evaluated) AS records
    FROM dq.v_rule_scorecard GROUP BY source_table
), bad AS (
    SELECT source_table,
           COUNT(DISTINCT record_key) AS records_with_issues,
           COUNT(DISTINCT CASE WHEN severity = 'High' THEN record_key END) AS records_with_high_issues
    FROM dq.v_issue GROUP BY source_table
)
SELECT r.source_table, r.records,
       COALESCE(b.records_with_issues, 0) AS records_with_issues,
       COALESCE(b.records_with_high_issues, 0) AS records_with_high_issues,
       CAST(1.0 - 1.0 * COALESCE(b.records_with_issues, 0) / NULLIF(r.records, 0) AS DECIMAL(6, 4)) AS dq_score
FROM recs AS r
LEFT JOIN bad AS b ON b.source_table = r.source_table;
GO

-- How well the rules find the defects planted by the data generators (record level)
CREATE OR ALTER VIEW dq.v_detection_score AS
WITH answers AS (
    SELECT DISTINCT source_table, record_key FROM dq.answer_key WHERE record_key <> N'*'
), column_wide AS (   -- defects logged for a whole column (e.g. 'mixed date formats'): any flag on that column is correct
    SELECT DISTINCT source_table, column_name FROM dq.answer_key WHERE record_key = N'*' AND column_name <> N'*'
), flagged AS (
    SELECT DISTINCT source_table, record_key, related_key, column_name FROM dq.v_issue
), detected AS (   -- planted defects that at least one rule caught
    SELECT a.source_table, a.record_key
    FROM answers AS a
    WHERE EXISTS (SELECT 1 FROM flagged AS f
                  WHERE f.source_table = a.source_table
                    AND (f.record_key = a.record_key OR f.related_key = a.record_key))
), true_flags AS (   -- flagged records that really were planted defects
    SELECT DISTINCT f.source_table, f.record_key
    FROM flagged AS f
    WHERE EXISTS (SELECT 1 FROM answers AS a
                  WHERE a.source_table = f.source_table
                    AND (a.record_key = f.record_key OR a.record_key = f.related_key))
       OR EXISTS (SELECT 1 FROM column_wide AS w
                  WHERE w.source_table = f.source_table AND w.column_name = f.column_name)
)
SELECT t.source_table,
       (SELECT COUNT(*) FROM answers a WHERE a.source_table = t.source_table) AS planted_defect_records,
       (SELECT COUNT(*) FROM detected d WHERE d.source_table = t.source_table) AS detected,
       (SELECT COUNT(DISTINCT record_key) FROM flagged f WHERE f.source_table = t.source_table) AS flagged_records,
       (SELECT COUNT(*) FROM true_flags tf WHERE tf.source_table = t.source_table) AS correctly_flagged,
       CAST(1.0 * (SELECT COUNT(*) FROM detected d WHERE d.source_table = t.source_table)
            / NULLIF((SELECT COUNT(*) FROM answers a WHERE a.source_table = t.source_table), 0) AS DECIMAL(5, 3)) AS recall,
       CAST(1.0 * (SELECT COUNT(*) FROM true_flags tf WHERE tf.source_table = t.source_table)
            / NULLIF((SELECT COUNT(DISTINCT record_key) FROM flagged f WHERE f.source_table = t.source_table), 0) AS DECIMAL(5, 3)) AS precision
FROM (SELECT source_table FROM answers UNION SELECT source_table FROM flagged) AS t;
GO
