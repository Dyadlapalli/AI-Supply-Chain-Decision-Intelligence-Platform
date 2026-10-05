/*
    04_audit_tables.sql
    Load log written by 04_Database/load_raw.py. Never dropped: load history must survive redeploys.
    Raw tables themselves are created by the loader from each file's header (schema-on-read landing).
*/
IF OBJECT_ID(N'audit.load_log') IS NULL
BEGIN
    CREATE TABLE audit.load_log (
        load_id             VARCHAR(60)    NOT NULL CONSTRAINT PK_audit_load_log PRIMARY KEY,
        batch_id            VARCHAR(30)    NOT NULL,   -- one per loader run
        source_system       VARCHAR(30)    NOT NULL,   -- Master Data / ERP / Business Files / SharePoint / External
        dataset             VARCHAR(80)    NOT NULL,
        target_table        VARCHAR(128)   NOT NULL,
        source_file         NVARCHAR(400)  NOT NULL,   -- path relative to the repository
        file_sha256         CHAR(64)       NULL,       -- proves exactly which file version was loaded
        file_modified_at    DATETIME2(0)   NULL,
        source_columns      NVARCHAR(MAX)  NULL,       -- original header names, JSON
        rows_read           INT            NULL,
        rows_loaded         INT            NULL,
        status              VARCHAR(10)    NOT NULL
            CONSTRAINT CK_audit_load_log_status CHECK (status IN ('running', 'ok', 'warning', 'failed', 'skipped')),
        note                NVARCHAR(1000) NULL,       -- schema drift, warnings, or the error message
        started_at          DATETIME2(0)   NOT NULL,
        finished_at         DATETIME2(0)   NULL
    );
    CREATE INDEX IX_audit_load_log_dataset ON audit.load_log (dataset, started_at DESC);
END
GO

-- Latest load per dataset: the source for data freshness (DQ-03)
CREATE OR ALTER VIEW audit.v_latest_load AS
SELECT *
FROM (
    SELECT l.*,
           ROW_NUMBER() OVER (PARTITION BY l.dataset ORDER BY l.started_at DESC) AS rn
    FROM audit.load_log AS l
) AS x
WHERE rn = 1;
GO
