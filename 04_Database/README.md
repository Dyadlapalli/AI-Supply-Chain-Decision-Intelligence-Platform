# Database

SQL Server scripts for the platform database `SupplyChainDI`. The design is documented in [2.3 Data_Model_Design.md](../02_Architecture/2.3%20Data_Model_Design.md).

## Contents

| Script | Creates |
|---|---|
| `sql/00_create_database.sql` | The `SupplyChainDI` database (local SQL Server only) |
| `sql/01_create_schemas.sql` | Layers: `raw`, `clean`, `mart`, `dq`, `audit` |
| `sql/02_mart_dimensions.sql` | 11 dimensions, including the generated calendar (2018–2027) and Unknown members |
| `sql/03_mart_facts.sql` | 12 fact tables with foreign keys and columnstore indexes |
| `deploy.ps1` | Runs all scripts in order. Safe to rerun: it rebuilds the `mart` tables |

## Deploy

```powershell
.\04_Database\deploy.ps1
```

On Azure SQL Database, create the database in the portal, then run the scripts from `01_` onward.

## Connecting (SSMS, Power BI, Python)

Use server name **`np:localhost`** with Windows Authentication, and tick **Trust server certificate**.

On this domain-joined laptop, Windows Authentication over the default local connection fails with *"The login is from an untrusted domain"*. The `np:` prefix connects over named pipes, which authenticates correctly. TCP/IP is disabled by default on SQL Server Developer Edition.
