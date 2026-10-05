/*
    02_mart_dimensions.sql
    Star schema dimensions. Re-runnable: drops mart facts and dimensions, then recreates dimensions.
    Every dimension gets an Unknown member with key -1.
*/

-- Facts reference dimensions, so they are dropped first
DROP TABLE IF EXISTS mart.FactSalesOrderLine, mart.FactPurchaseOrderLine, mart.FactGoodsReceiptLine,
    mart.FactInventoryTransaction, mart.FactInventorySnapshotDaily, mart.FactEconomicIndicator,
    mart.FactWeatherEvent, mart.FactSupplierException, mart.FactForecastOverride, mart.FactForecast,
    mart.FactDataQualityResult, mart.FactDataLoad;
DROP TABLE IF EXISTS mart.DimEquipment;  -- references DimProduct, so it goes first
DROP TABLE IF EXISTS mart.DimDate, mart.DimBranch, mart.DimProduct, mart.DimPart, mart.DimSupplier,
    mart.DimCustomer, mart.DimTransactionType, mart.DimInventoryPolicy, mart.DimIndicator, mart.DimDQRule;
GO

/* ---------------------------------------------------------------------------------------------
   DimDate - generated calendar 2018-01-01 to 2027-12-31
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimDate (
    date_key                INT          NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,  -- YYYYMMDD
    [date]                  DATE         NOT NULL CONSTRAINT UQ_DimDate_date UNIQUE,
    day_of_month            TINYINT      NOT NULL,
    day_of_week             TINYINT      NOT NULL,  -- 1 = Monday ... 7 = Sunday
    day_name                VARCHAR(9)   NOT NULL,
    is_weekend              BIT          NOT NULL,
    is_holiday              BIT          NOT NULL,
    is_business_day         BIT          NOT NULL,
    week_start_date         DATE         NOT NULL,  -- Monday
    month_number            TINYINT      NOT NULL,
    month_name              VARCHAR(9)   NOT NULL,
    month_short             CHAR(3)      NOT NULL,
    month_start_date        DATE         NOT NULL,
    month_end_date          DATE         NOT NULL,
    is_month_end            BIT          NOT NULL,
    year_month              CHAR(7)      NOT NULL,  -- 2026-09
    quarter_number          TINYINT      NOT NULL,
    year_quarter            CHAR(7)      NOT NULL,  -- 2026-Q3
    [year]                  SMALLINT     NOT NULL,
    season                  VARCHAR(7)   NOT NULL,
    is_construction_season  BIT          NOT NULL   -- April through October
);
GO

WITH n AS (
    SELECT TOP (DATEDIFF(DAY, '2018-01-01', '2027-12-31') + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
d AS (
    SELECT DATEADD(DAY, i, CAST('2018-01-01' AS DATE)) AS dt FROM n
),
f AS (
    SELECT dt,
           DATEDIFF(DAY, '1900-01-01', dt) % 7 + 1 AS dow,  -- 1900-01-01 was a Monday; independent of DATEFIRST
           MONTH(dt) AS m, DAY(dt) AS dd, YEAR(dt) AS y
    FROM d
),
h AS (
    SELECT f.*,
           CASE
               WHEN (m = 1 AND dd = 1) OR (m = 7 AND dd = 4) OR (m = 12 AND dd IN (24, 25)) THEN 1
               WHEN m = 5 AND dow = 1 AND dd > 24 THEN 1                    -- Memorial Day: last Monday of May
               WHEN m = 9 AND dow = 1 AND dd <= 7 THEN 1                    -- Labor Day: first Monday of September
               WHEN m = 11 AND dow = 4 AND dd BETWEEN 22 AND 28 THEN 1      -- Thanksgiving: fourth Thursday
               ELSE 0
           END AS hol
    FROM f
)
INSERT INTO mart.DimDate
SELECT  y * 10000 + m * 100 + dd,
        dt, dd, dow,
        CHOOSE(dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
        IIF(dow >= 6, 1, 0),
        hol,
        IIF(dow < 6 AND hol = 0, 1, 0),
        DATEADD(DAY, 1 - dow, dt),
        m,
        CHOOSE(m, 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
               'October', 'November', 'December'),
        CHOOSE(m, 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'),
        DATEFROMPARTS(y, m, 1),
        EOMONTH(dt),
        IIF(dt = EOMONTH(dt), 1, 0),
        CONCAT(y, '-', RIGHT(CONCAT('0', m), 2)),
        (m - 1) / 3 + 1,
        CONCAT(y, '-Q', (m - 1) / 3 + 1),
        y,
        CASE WHEN m IN (12, 1, 2) THEN 'Winter' WHEN m IN (3, 4, 5) THEN 'Spring'
             WHEN m IN (6, 7, 8) THEN 'Summer' ELSE 'Fall' END,
        IIF(m BETWEEN 4 AND 10, 1, 0)
FROM h;

-- Unknown date for missing / invalid dates
INSERT INTO mart.DimDate VALUES (-1, '1900-01-01', 0, 0, 'Unknown', 0, 0, 0, '1900-01-01', 0, 'Unknown', 'UNK',
                                 '1900-01-01', '1900-01-01', 0, 'Unknown', 0, 'Unknown', 0, 'Unknown', 0);
GO

/* ---------------------------------------------------------------------------------------------
   DimBranch
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimBranch (
    branch_key      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimBranch PRIMARY KEY,
    branch_id       VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimBranch_id UNIQUE,
    branch_name     NVARCHAR(60)  NOT NULL,
    region          VARCHAR(20)   NOT NULL,
    state_code      CHAR(2)       NOT NULL,
    branch_type     VARCHAR(30)   NOT NULL,
    open_date       DATE          NULL,
    is_active       BIT           NOT NULL,
    latitude        DECIMAL(9, 6) NULL,
    longitude       DECIMAL(9, 6) NULL,
    dw_loaded_at    DATETIME2(0)  NOT NULL CONSTRAINT DF_DimBranch_loaded DEFAULT SYSUTCDATETIME()
);

/* ---------------------------------------------------------------------------------------------
   DimProduct - equipment models with category / family / segment flattened in
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimProduct (
    product_key             INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimProduct PRIMARY KEY,
    product_id              VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimProduct_id UNIQUE,
    product_name            NVARCHAR(60)  NOT NULL,
    product_category_id     VARCHAR(10)   NOT NULL,
    product_category_name   NVARCHAR(60)  NOT NULL,
    product_family_id       VARCHAR(10)   NOT NULL,
    product_family_name     NVARCHAR(60)  NOT NULL,
    business_segment        NVARCHAR(40)  NOT NULL,
    criticality             VARCHAR(10)   NOT NULL,
    lifecycle_status        VARCHAR(20)   NOT NULL,
    dw_loaded_at            DATETIME2(0)  NOT NULL CONSTRAINT DF_DimProduct_loaded DEFAULT SYSUTCDATETIME()
);

/* ---------------------------------------------------------------------------------------------
   DimInventoryPolicy - stocking rules by part category x criticality
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimInventoryPolicy (
    policy_key              INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimInventoryPolicy PRIMARY KEY,
    part_category           NVARCHAR(40)  NOT NULL,
    criticality             VARCHAR(10)   NOT NULL,
    service_level_target    DECIMAL(4, 3) NULL,
    review_cycle_days       SMALLINT      NULL,
    min_days_of_supply      SMALLINT      NULL,
    max_days_of_supply      SMALLINT      NULL,
    dw_loaded_at            DATETIME2(0)  NOT NULL CONSTRAINT DF_DimInventoryPolicy_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_DimInventoryPolicy UNIQUE (part_category, criticality)
);

/* ---------------------------------------------------------------------------------------------
   DimSupplier - SCD Type 2: one row per version of a supplier
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimSupplier (
    supplier_key                    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimSupplier PRIMARY KEY,
    supplier_id                     VARCHAR(10)   NOT NULL,
    supplier_name                   NVARCHAR(100) NOT NULL,
    supplier_tier                   VARCHAR(10)   NOT NULL,
    supplier_type                   VARCHAR(40)   NOT NULL,
    city                            NVARCHAR(60)  NULL,
    state_code                      VARCHAR(3)    NULL,
    lead_time_days                  SMALLINT      NULL,      -- master (planned) lead time for this version
    on_time_delivery_pct_master     DECIMAL(5, 1) NULL,
    payment_terms                   VARCHAR(10)   NULL,
    is_active                       BIT           NOT NULL,
    valid_from                      DATE          NOT NULL,
    valid_to                        DATE          NOT NULL CONSTRAINT DF_DimSupplier_valid_to DEFAULT '9999-12-31',
    is_current                      BIT           NOT NULL CONSTRAINT DF_DimSupplier_current DEFAULT 1,
    dw_loaded_at                    DATETIME2(0)  NOT NULL CONSTRAINT DF_DimSupplier_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_DimSupplier_version UNIQUE (supplier_id, valid_from)
);

/* ---------------------------------------------------------------------------------------------
   DimPart - part master with product hierarchy, policy, and critical-part flags flattened in
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimPart (
    part_key                INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimPart PRIMARY KEY,
    part_id                 VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimPart_id UNIQUE,
    part_number             VARCHAR(20)   NOT NULL,
    part_description        NVARCHAR(100) NOT NULL,
    part_category           NVARCHAR(40)  NOT NULL,
    criticality             VARCHAR(10)   NOT NULL,
    unit_cost_usd           DECIMAL(12, 2) NULL,
    unit_of_measure         VARCHAR(5)    NOT NULL,
    reman_available         BIT           NOT NULL,
    primary_supplier_id     VARCHAR(10)   NULL,
    primary_product_id      VARCHAR(10)   NULL,
    primary_model_name      NVARCHAR(60)  NULL,
    product_category_name   NVARCHAR(60)  NULL,
    product_family_name     NVARCHAR(60)  NULL,
    business_segment        NVARCHAR(40)  NULL,
    service_level_target    DECIMAL(4, 3) NULL,       -- from DimInventoryPolicy
    is_critical_part        BIT           NOT NULL CONSTRAINT DF_DimPart_critical DEFAULT 0,
    critical_priority       CHAR(2)       NULL,       -- P1 / P2 from Critical_Parts_List
    critical_scope          VARCHAR(20)   NULL,
    created_date            DATE          NULL,
    is_active               BIT           NOT NULL,
    dw_loaded_at            DATETIME2(0)  NOT NULL CONSTRAINT DF_DimPart_loaded DEFAULT SYSUTCDATETIME()
);
CREATE UNIQUE INDEX UQ_DimPart_number ON mart.DimPart (part_number);

/* ---------------------------------------------------------------------------------------------
   DimCustomer
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimCustomer (
    customer_key    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimCustomer PRIMARY KEY,
    customer_id     VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimCustomer_id UNIQUE,
    customer_name   NVARCHAR(100) NOT NULL,
    dw_loaded_at    DATETIME2(0)  NOT NULL CONSTRAINT DF_DimCustomer_loaded DEFAULT SYSUTCDATETIME()
);

/* ---------------------------------------------------------------------------------------------
   DimEquipment - serialized machines in the field
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimEquipment (
    equipment_key           INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimEquipment PRIMARY KEY,
    equipment_id            VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimEquipment_id UNIQUE,
    serial_number           VARCHAR(20)   NOT NULL,
    product_key             INT           NOT NULL CONSTRAINT FK_DimEquipment_Product REFERENCES mart.DimProduct (product_key),
    equipment_model         NVARCHAR(60)  NOT NULL,
    model_year              SMALLINT      NULL,
    service_meter_hours     INT           NULL,
    home_branch_id          VARCHAR(10)   NULL,
    ownership               VARCHAR(20)   NULL,
    dw_loaded_at            DATETIME2(0)  NOT NULL CONSTRAINT DF_DimEquipment_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_DimEquipment_serial ON mart.DimEquipment (serial_number);

/* ---------------------------------------------------------------------------------------------
   DimTransactionType - static reference for inventory movements
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimTransactionType (
    txn_type_key        INT          NOT NULL CONSTRAINT PK_DimTransactionType PRIMARY KEY,
    txn_type            VARCHAR(40)  NOT NULL CONSTRAINT UQ_DimTransactionType UNIQUE,
    txn_category        VARCHAR(20)  NOT NULL,
    direction           SMALLINT     NOT NULL,  -- +1 adds stock, -1 removes stock, 0 either
    is_cogs             BIT          NOT NULL,  -- counts toward cost of goods (INV-02)
    is_replenishment    BIT          NOT NULL   -- counts toward replenishment (NET-01)
);
INSERT INTO mart.DimTransactionType VALUES
    (-1, 'Unknown',                  'Unknown',    0, 0, 0),
    (1,  'Opening Balance',          'Opening',    1, 0, 0),
    (2,  'Goods Issue',              'Issue',     -1, 1, 0),
    (3,  'Goods Issue - Backorder',  'Issue',     -1, 1, 0),
    (4,  'Goods Receipt',            'Receipt',    1, 0, 1),
    (5,  'Transfer In',              'Transfer',   1, 0, 1),
    (6,  'Transfer Out',             'Transfer',  -1, 0, 0),
    (7,  'Cycle Count Adjustment',   'Adjustment', 0, 0, 0),
    (8,  'Customer Return',          'Return',     1, 1, 0);  -- reduces COGS (positive qty offsets issues)

/* ---------------------------------------------------------------------------------------------
   DimIndicator - external data series (FRED, EIA)
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimIndicator (
    indicator_key   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimIndicator PRIMARY KEY,
    series_id       VARCHAR(40)   NOT NULL CONSTRAINT UQ_DimIndicator_id UNIQUE,
    series_name     NVARCHAR(120) NOT NULL,
    category        VARCHAR(30)   NOT NULL,
    geography       VARCHAR(40)   NOT NULL,
    frequency       VARCHAR(10)   NOT NULL,
    units           NVARCHAR(60)  NULL,
    source          VARCHAR(30)   NOT NULL,
    dw_loaded_at    DATETIME2(0)  NOT NULL CONSTRAINT DF_DimIndicator_loaded DEFAULT SYSUTCDATETIME()
);

/* ---------------------------------------------------------------------------------------------
   DimDQRule - data quality rules (populated in Phase 3)
--------------------------------------------------------------------------------------------- */
CREATE TABLE mart.DimDQRule (
    rule_key        INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_DimDQRule PRIMARY KEY,
    rule_id         VARCHAR(20)   NOT NULL CONSTRAINT UQ_DimDQRule_id UNIQUE,
    rule_name       NVARCHAR(150) NOT NULL,
    dq_dimension    VARCHAR(15)   NOT NULL
        CONSTRAINT CK_DimDQRule_dimension CHECK (dq_dimension IN ('Completeness', 'Validity', 'Consistency',
                                                                  'Uniqueness', 'Integrity', 'Unknown')),
    severity        VARCHAR(10)   NOT NULL
        CONSTRAINT CK_DimDQRule_severity CHECK (severity IN ('High', 'Medium', 'Low', 'Unknown')),
    source_system   VARCHAR(30)   NOT NULL,
    source_table    VARCHAR(60)   NOT NULL,
    column_name     VARCHAR(60)   NULL,
    rule_description NVARCHAR(400) NULL,
    is_active       BIT           NOT NULL CONSTRAINT DF_DimDQRule_active DEFAULT 1
);
GO

/* ---------------------------------------------------------------------------------------------
   Unknown members (key -1)
--------------------------------------------------------------------------------------------- */
SET IDENTITY_INSERT mart.DimBranch ON;
INSERT INTO mart.DimBranch (branch_key, branch_id, branch_name, region, state_code, branch_type, is_active)
VALUES (-1, 'UNKNOWN', N'Unknown', 'Unknown', '--', 'Unknown', 0);
SET IDENTITY_INSERT mart.DimBranch OFF;

SET IDENTITY_INSERT mart.DimProduct ON;
INSERT INTO mart.DimProduct (product_key, product_id, product_name, product_category_id, product_category_name,
                             product_family_id, product_family_name, business_segment, criticality, lifecycle_status)
VALUES (-1, 'UNKNOWN', N'Unknown', 'UNKNOWN', N'Unknown', 'UNKNOWN', N'Unknown', N'Unknown', 'Unknown', 'Unknown');
SET IDENTITY_INSERT mart.DimProduct OFF;

SET IDENTITY_INSERT mart.DimInventoryPolicy ON;
INSERT INTO mart.DimInventoryPolicy (policy_key, part_category, criticality) VALUES (-1, N'Unknown', 'Unknown');
SET IDENTITY_INSERT mart.DimInventoryPolicy OFF;

SET IDENTITY_INSERT mart.DimSupplier ON;
INSERT INTO mart.DimSupplier (supplier_key, supplier_id, supplier_name, supplier_tier, supplier_type, is_active, valid_from)
VALUES (-1, 'UNKNOWN', N'Unknown', 'Unknown', 'Unknown', 0, '1900-01-01');
SET IDENTITY_INSERT mart.DimSupplier OFF;

SET IDENTITY_INSERT mart.DimPart ON;
INSERT INTO mart.DimPart (part_key, part_id, part_number, part_description, part_category, criticality,
                          unit_of_measure, reman_available, is_active)
VALUES (-1, 'UNKNOWN', 'UNKNOWN', N'Unknown', N'Unknown', 'Unknown', '--', 0, 0);
SET IDENTITY_INSERT mart.DimPart OFF;

SET IDENTITY_INSERT mart.DimCustomer ON;
INSERT INTO mart.DimCustomer (customer_key, customer_id, customer_name) VALUES (-1, 'UNKNOWN', N'Unknown');
SET IDENTITY_INSERT mart.DimCustomer OFF;

SET IDENTITY_INSERT mart.DimEquipment ON;
INSERT INTO mart.DimEquipment (equipment_key, equipment_id, serial_number, product_key, equipment_model)
VALUES (-1, 'UNKNOWN', 'UNKNOWN', -1, N'Unknown');
SET IDENTITY_INSERT mart.DimEquipment OFF;

SET IDENTITY_INSERT mart.DimIndicator ON;
INSERT INTO mart.DimIndicator (indicator_key, series_id, series_name, category, geography, frequency, source)
VALUES (-1, 'UNKNOWN', N'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown');
SET IDENTITY_INSERT mart.DimIndicator OFF;

SET IDENTITY_INSERT mart.DimDQRule ON;
INSERT INTO mart.DimDQRule (rule_key, rule_id, rule_name, dq_dimension, severity, source_system, source_table)
VALUES (-1, 'UNKNOWN', N'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown');
SET IDENTITY_INSERT mart.DimDQRule OFF;
GO
