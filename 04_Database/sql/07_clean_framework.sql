/*
    07_clean_framework.sql
    Shared pieces of the clean layer: parsing functions, Data Steward reference data, and the quarantine table.
    The clean tables themselves are built by the procedures in the 04_Database/clean folder (run_clean.py).
*/

/* ---------------------------------------------------------------------------------------------
   Parsing functions
--------------------------------------------------------------------------------------------- */

-- Any date format found in the sources -> DATE. NULL when the value cannot be read.
--   2026-03-14 | 2026-03-14T00:00:00 | 20260314 | 03/14/2026 | 03/14/26 | 14-Mar-26 | 14-Mar-2026
--   46095 (Excel serial) | Q1 2026 | Mar 2026 | 2026-03
CREATE OR ALTER FUNCTION clean.fn_to_date (@s NVARCHAR(100))
RETURNS DATE
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @t NVARCHAR(100) = LTRIM(RTRIM(@s));
    IF @t IS NULL OR @t = N'' RETURN NULL;
    IF @t LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      RETURN TRY_CONVERT(DATE, LEFT(@t, 10), 23);
    IF @t LIKE N'[12][0-9][0-9][0-9]-[01][0-9]'                  RETURN TRY_CONVERT(DATE, @t + N'-01', 23);
    IF @t LIKE N'[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         RETURN TRY_CONVERT(DATE, @t, 112);
    IF @t NOT LIKE N'%[^0-9]%' AND LEN(@t) = 5                   RETURN DATEADD(DAY, CAST(@t AS INT), CAST('1899-12-30' AS DATE));
    IF @t LIKE N'%/%/[0-9][0-9][0-9][0-9]'                       RETURN TRY_CONVERT(DATE, @t, 101);
    IF @t LIKE N'%/%/[0-9][0-9]'                                 RETURN TRY_CONVERT(DATE, @t, 1);
    IF @t LIKE N'[0-9]%-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' RETURN TRY_CONVERT(DATE, REPLACE(@t, N'-', N' '), 106);
    IF @t LIKE N'[0-9]%-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]'     RETURN TRY_CONVERT(DATE, REPLACE(@t, N'-', N' '), 6);
    IF @t LIKE N'Q[1-4] [12][0-9][0-9][0-9]'                     RETURN DATEFROMPARTS(CAST(RIGHT(@t, 4) AS INT), (CAST(SUBSTRING(@t, 2, 1) AS INT) - 1) * 3 + 1, 1);
    IF @t LIKE N'[A-Za-z][A-Za-z][A-Za-z]% [12][0-9][0-9][0-9]'  RETURN TRY_CONVERT(DATE, N'01 ' + @t, 106);
    RETURN TRY_CONVERT(DATE, @t);
END
GO

-- Timestamps: ISO 'YYYY-MM-DD HH:MM:SS' keeps its time; anything else falls back to the date at midnight
CREATE OR ALTER FUNCTION clean.fn_to_datetime (@s NVARCHAR(100))
RETURNS DATETIME2(0)
-- not schema-bound: it calls another function, which must stay redeployable
AS
BEGIN
    DECLARE @t NVARCHAR(100) = LTRIM(RTRIM(@s));
    IF @t LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
        RETURN TRY_CONVERT(DATETIME2(0), @t, 120);
    RETURN CAST(clean.fn_to_date(@t) AS DATETIME2(0));
END
GO

-- Money / numbers stored as text: '$1,234.50' -> 1234.50
CREATE OR ALTER FUNCTION clean.fn_to_money (@s NVARCHAR(100))
RETURNS DECIMAL(14, 2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN TRY_CAST(REPLACE(REPLACE(LTRIM(RTRIM(@s)), N'$', N''), N',', N'') AS DECIMAL(14, 2));
END
GO

-- Integers stored as text, tolerating a unit suffix: '18 days' -> 18, '7' -> 7, 'TBD' -> NULL
CREATE OR ALTER FUNCTION clean.fn_to_int (@s NVARCHAR(100))
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @t NVARCHAR(100) = LTRIM(RTRIM(@s));
    IF @t LIKE N'%[0-9] days' OR @t LIKE N'%[0-9] day' SET @t = LEFT(@t, CHARINDEX(N' ', @t) - 1);
    RETURN TRY_CAST(TRY_CAST(@t AS DECIMAL(18, 4)) AS INT);
END
GO

-- Canonical Caterpillar part number: '1r0750', ' 1R 0750', '01R-0750' -> '1R-0750'; '3261644' -> '326-1644'
CREATE OR ALTER FUNCTION clean.fn_canon_part (@s NVARCHAR(100))
RETURNS NVARCHAR(20)
-- not schema-bound: it calls another function, which must stay redeployable
AS
BEGIN
    DECLARE @n NVARCHAR(100) = dq.fn_norm_part(@s);
    IF @n COLLATE Latin1_General_BIN2 LIKE N'[1-9][0-9][0-9][0-9][0-9][0-9][0-9]' RETURN LEFT(@n, 3) + N'-' + RIGHT(@n, 4);
    IF @n COLLATE Latin1_General_BIN2 LIKE N'[1-9][A-Z][0-9][0-9][0-9][0-9]'      RETURN LEFT(@n, 2) + N'-' + RIGHT(@n, 4);
    RETURN NULL;
END
GO

-- Proper case for names: '  RICHMOND' -> 'Richmond', 'south boston' -> 'South Boston'
CREATE OR ALTER FUNCTION clean.fn_proper (@s NVARCHAR(200))
RETURNS NVARCHAR(200)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @t NVARCHAR(200) = LOWER(LTRIM(RTRIM(@s))), @i INT = 1, @out NVARCHAR(200) = N'', @prev NCHAR(1) = N' ';
    IF @t IS NULL RETURN NULL;
    WHILE @i <= LEN(@t)
    BEGIN
        SET @out += IIF(@prev IN (N' ', N'-', N'.'), UPPER(SUBSTRING(@t, @i, 1)), SUBSTRING(@t, @i, 1));
        SET @prev = SUBSTRING(@t, @i, 1);
        SET @i += 1;
    END
    RETURN @out;
END
GO

/* ---------------------------------------------------------------------------------------------
   Reference data maintained by the Data Steward
   (approved values and known synonyms - the things rules can detect but text cleaning cannot fix)
--------------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'clean.ref_state') IS NULL
CREATE TABLE clean.ref_state (state_code VARCHAR(3) NOT NULL PRIMARY KEY, state_name NVARCHAR(40) NOT NULL UNIQUE);

IF OBJECT_ID(N'clean.ref_product_family') IS NULL
CREATE TABLE clean.ref_product_family (
    product_family_name NVARCHAR(60) NOT NULL PRIMARY KEY,
    product_family_code VARCHAR(5)   NOT NULL,
    business_segment    NVARCHAR(40) NOT NULL
);

-- Any other spelling -> approved value. domain = 'family' | 'category' | 'part_category' | 'criticality' | 'uom' | 'txn_type' | 'tier'
IF OBJECT_ID(N'clean.ref_synonym') IS NULL
CREATE TABLE clean.ref_synonym (
    domain          VARCHAR(20)   NOT NULL,
    source_value    NVARCHAR(100) NOT NULL,
    approved_value  NVARCHAR(100) NOT NULL,
    CONSTRAINT PK_clean_ref_synonym PRIMARY KEY (domain, source_value)
);
GO

MERGE clean.ref_state AS t
USING (VALUES ('VA', N'Virginia'), ('WV', N'West Virginia'), ('MD', N'Maryland'), ('DE', N'Delaware'),
              ('IL', N'Illinois'), ('PA', N'Pennsylvania'), ('GA', N'Georgia'), ('MS', N'Mississippi'),
              ('MN', N'Minnesota'), ('OH', N'Ohio'), ('CO', N'Colorado'), ('OR', N'Oregon'), ('TX', N'Texas'),
              ('TN', N'Tennessee'), ('CA', N'California'), ('SC', N'South Carolina'), ('MI', N'Michigan'),
              ('IN', N'Indiana'), ('UK', N'United Kingdom')) AS s (state_code, state_name)
ON t.state_code = s.state_code
WHEN NOT MATCHED THEN INSERT VALUES (s.state_code, s.state_name);

MERGE clean.ref_product_family AS t
USING (VALUES (N'Excavation', 'EXC', N'Construction Industries'), (N'Earthmoving', 'EMV', N'Construction Industries'),
              (N'Material Handling', 'MHD', N'Construction Industries'), (N'Power Systems', 'PWR', N'Energy & Transportation'),
              (N'Road Construction', 'RDC', N'Construction Industries'), (N'Mining', 'MIN', N'Resource Industries'),
              (N'Underground Mining', 'UGM', N'Resource Industries'), (N'Forestry', 'FOR', N'Construction Industries'),
              (N'Work Tools & Attachments', 'WTA', N'Construction Industries'),
              (N'Marine & Oil and Gas', 'MOG', N'Energy & Transportation')) AS s (n, c, seg)
ON t.product_family_name = s.n
WHEN MATCHED THEN UPDATE SET product_family_code = s.c, business_segment = s.seg
WHEN NOT MATCHED THEN INSERT VALUES (s.n, s.c, s.seg);

MERGE clean.ref_synonym AS t
USING (VALUES
    ('family', N'Paving', N'Road Construction'), ('family', N'Earth Moving', N'Earthmoving'),
    ('family', N'Marine and O&G', N'Marine & Oil and Gas'), ('family', N'Power Sys.', N'Power Systems'),
    ('category', N'Compact Track Loader (CTL)', N'Compact Track Loaders'), ('category', N'OHT', N'Off-Highway Trucks'),
    ('category', N'Hydraulic Excavators', N'Excavators'),
    ('part_category', N'GET', N'Ground Engaging Tools'), ('part_category', N'Undercarrage', N'Undercarriage'),
    ('criticality', N'Hi', N'High'), ('criticality', N'CRITICAL', N'High'), ('criticality', N'med', N'Medium'),
    ('uom', N'each', N'EA'), ('uom', N'Ea.', N'EA'), ('uom', N'PC', N'EA'), ('uom', N'ea', N'EA'),
    ('tier', N'T1', N'Tier 1'), ('tier', N'1', N'Tier 1'), ('tier', N'tier 2', N'Tier 2'), ('tier', N'Tier-3', N'Tier 3'),
    ('segment', N'CI', N'Construction Industries'),
    ('txn_type', N'ISS', N'Goods Issue'), ('txn_type', N'issue', N'Goods Issue'), ('txn_type', N'GI', N'Goods Issue'),
    ('txn_type', N'RCPT', N'Goods Receipt'), ('txn_type', N'GR', N'Goods Receipt'), ('txn_type', N'receipt', N'Goods Receipt')
) AS s (domain, source_value, approved_value)
ON t.domain = s.domain AND t.source_value COLLATE Latin1_General_BIN2 = s.source_value COLLATE Latin1_General_BIN2
WHEN MATCHED THEN UPDATE SET approved_value = s.approved_value
WHEN NOT MATCHED THEN INSERT VALUES (s.domain, s.source_value, s.approved_value);
GO

/* ---------------------------------------------------------------------------------------------
   Quarantine: records held back from the clean layer, with the reason. Rebuilt on every clean run.
--------------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'clean.quarantine') IS NULL
CREATE TABLE clean.quarantine (
    source_table    VARCHAR(128)   NOT NULL,
    record_key      NVARCHAR(200)  NOT NULL,
    reason_rule_id  VARCHAR(20)    NOT NULL,   -- dq rule, or CLEAN-xx for decisions made while cleaning
    reason          NVARCHAR(400)  NOT NULL,
    quarantined_at  DATETIME2(0)   NOT NULL CONSTRAINT DF_clean_quarantine_at DEFAULT SYSUTCDATETIME()
);
GO
