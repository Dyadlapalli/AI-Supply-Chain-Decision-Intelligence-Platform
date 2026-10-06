/*
    04_Database/clean/04_external.sql
    clean.usp_build_external: types the real API data (FRED, EIA, NOAA). Little needs repair - it is
    published data - but values are typed, unreadable observations dropped, and test alerts removed.
*/
CREATE OR ALTER PROCEDURE clean.usp_build_external
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM clean.quarantine WHERE source_table LIKE 'raw.ext[_]%';

    DROP TABLE IF EXISTS clean.economic_indicator;
    SELECT ISNULL(CAST(series_id AS VARCHAR(40)), '') AS series_id, CAST(series_name AS NVARCHAR(120)) AS series_name,
           CAST(category AS VARCHAR(30)) AS category, CAST(geography AS VARCHAR(40)) AS geography,
           CAST(frequency AS VARCHAR(10)) AS frequency, CAST(units AS NVARCHAR(60)) AS units,
           ISNULL(TRY_CONVERT(DATE, [date], 23), '1900-01-01') AS observation_date,
           TRY_CAST([value] AS DECIMAL(18, 4)) AS [value], CAST(source AS VARCHAR(30)) AS source,
           TRY_CONVERT(DATETIME2(0), REPLACE(REPLACE(retrieved_at, N'T', N' '), N'Z', N''), 120) AS retrieved_at
    INTO clean.economic_indicator
    FROM raw.ext_economic_indicators
    WHERE TRY_CAST([value] AS DECIMAL(18, 4)) IS NOT NULL AND TRY_CONVERT(DATE, [date], 23) IS NOT NULL;   -- X-EI-01
    EXEC (N'ALTER TABLE clean.economic_indicator ADD CONSTRAINT PK_clean_economic_indicator PRIMARY KEY (series_id, observation_date)');

    DROP TABLE IF EXISTS clean.fuel_price;
    SELECT ISNULL(TRY_CONVERT(DATE, week_of, 23), '1900-01-01') AS week_of, ISNULL(CAST(region AS VARCHAR(40)), '') AS region,
           CAST(product AS VARCHAR(40)) AS product, TRY_CAST(price_usd_per_gal AS DECIMAL(8, 3)) AS price_usd_per_gal,
           CAST(source AS VARCHAR(30)) AS source
    INTO clean.fuel_price
    FROM raw.ext_fuel_prices
    WHERE TRY_CAST(price_usd_per_gal AS DECIMAL(8, 3)) IS NOT NULL;
    EXEC (N'ALTER TABLE clean.fuel_price ADD CONSTRAINT PK_clean_fuel_price PRIMARY KEY (week_of, region)');

    DROP TABLE IF EXISTS clean.storm_event;
    SELECT ISNULL(TRY_CAST(event_id AS BIGINT), 0) AS event_id, TRY_CAST(episode_id AS BIGINT) AS episode_id,
           CAST(state AS CHAR(2)) AS state_code, CAST(county_or_zone AS NVARCHAR(80)) AS county_or_zone,
           CAST(zone_type AS VARCHAR(20)) AS zone_type, CAST(event_type AS VARCHAR(40)) AS event_type,
           TRY_CONVERT(DATETIME2(0), begin_datetime, 120) AS begin_datetime, TRY_CONVERT(DATETIME2(0), end_datetime, 120) AS end_datetime,
           CAST(timezone AS VARCHAR(10)) AS timezone,
           ISNULL(TRY_CAST(injuries AS INT), 0) AS injuries, ISNULL(TRY_CAST(deaths AS INT), 0) AS deaths,
           TRY_CAST(property_damage_usd AS DECIMAL(16, 2)) AS property_damage_usd, TRY_CAST(crop_damage_usd AS DECIMAL(16, 2)) AS crop_damage_usd,
           TRY_CAST(magnitude AS DECIMAL(10, 2)) AS magnitude, CAST(magnitude_type AS VARCHAR(5)) AS magnitude_type,
           TRY_CAST(begin_lat AS DECIMAL(9, 4)) AS begin_lat, TRY_CAST(begin_lon AS DECIMAL(9, 4)) AS begin_lon
    INTO clean.storm_event
    FROM raw.ext_storm_events;
    EXEC (N'ALTER TABLE clean.storm_event ADD CONSTRAINT PK_clean_storm_event PRIMARY KEY (event_id)');

    DROP TABLE IF EXISTS clean.weather_alert;
    SELECT CAST(alert_id AS NVARCHAR(200)) AS alert_id, CAST(state AS CHAR(2)) AS state_code, CAST(event AS NVARCHAR(100)) AS event,
           CAST(severity AS VARCHAR(20)) AS severity, CAST(urgency AS VARCHAR(20)) AS urgency, CAST(headline AS NVARCHAR(400)) AS headline,
           CAST(area_desc AS NVARCHAR(1000)) AS area_desc,
           TRY_CONVERT(DATETIMEOFFSET(0), effective) AS effective, TRY_CONVERT(DATETIMEOFFSET(0), expires) AS expires
    INTO clean.weather_alert
    FROM raw.ext_weather_alerts_active
    WHERE NOT EXISTS (SELECT 1 FROM dq.chk_X_WA_01 t WHERE t.record_key = raw.ext_weather_alerts_active.alert_id);   -- test messages

    INSERT INTO clean.quarantine (source_table, record_key, reason_rule_id, reason)
    SELECT 'raw.ext_weather_alerts_active', record_key, 'X-WA-01', N'Weather service test message, not a real alert'
    FROM dq.chk_X_WA_01;
END
GO
