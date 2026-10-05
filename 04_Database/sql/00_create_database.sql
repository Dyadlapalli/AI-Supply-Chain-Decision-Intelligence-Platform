/*
    00_create_database.sql
    Creates the platform database on a local SQL Server instance.
    Azure SQL Database: skip this script - create the database in the Azure portal, then run 01 onwards.
*/
IF DB_ID(N'SupplyChainDI') IS NULL
BEGIN
    CREATE DATABASE SupplyChainDI;
END
GO

ALTER DATABASE SupplyChainDI SET RECOVERY SIMPLE;  -- analytics database: rebuildable from raw files
GO
