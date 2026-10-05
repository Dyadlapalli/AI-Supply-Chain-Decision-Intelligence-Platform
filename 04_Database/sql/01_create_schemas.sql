/*
    01_create_schemas.sql
    Layers (see 02_Architecture/2.3 Data_Model_Design.md):
        raw   - source data exactly as received, all text
        clean - typed, standardized, de-duplicated
        mart  - star schema read by Power BI, forecasting, and AI agents
        dq    - data quality rules, results, quarantine, issue register
        audit - load log
*/
IF SCHEMA_ID(N'raw')   IS NULL EXEC (N'CREATE SCHEMA raw');
IF SCHEMA_ID(N'clean') IS NULL EXEC (N'CREATE SCHEMA clean');
IF SCHEMA_ID(N'mart')  IS NULL EXEC (N'CREATE SCHEMA mart');
IF SCHEMA_ID(N'dq')    IS NULL EXEC (N'CREATE SCHEMA dq');
IF SCHEMA_ID(N'audit') IS NULL EXEC (N'CREATE SCHEMA audit');
GO
