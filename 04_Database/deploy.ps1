<#
.SYNOPSIS
    Runs the SQL scripts in 04_Database/sql in order against a SQL Server instance.

.EXAMPLE
    .\04_Database\deploy.ps1                          # local default instance over named pipes, Windows authentication
    .\04_Database\deploy.ps1 -Server "localhost\SQL2" -Database SupplyChainDI

.NOTES
    Default server is "np:localhost" (named pipes). On this domain-joined laptop, Windows authentication over the
    default shared-memory connection fails with "login is from an untrusted domain"; named pipes (NTLM) works.
#>
param(
    [string]$Server = "np:localhost",
    [string]$Database = "SupplyChainDI"
)

$ErrorActionPreference = "Stop"
$sqlDir = Join-Path $PSScriptRoot "sql"

function Invoke-SqlFile([string]$File, [string]$Db) {
    $conn = New-Object System.Data.SqlClient.SqlConnection(
        "Server=$Server;Database=$Db;Integrated Security=True;TrustServerCertificate=True;Encrypt=True")
    $conn.Open()
    try {
        # Split on GO batch separators (a line containing only GO)
        $batches = [regex]::Split((Get-Content $File -Raw), '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() }
        foreach ($batch in $batches) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = 600
            [void]$cmd.ExecuteNonQuery()
        }
    }
    finally { $conn.Close() }
}

foreach ($file in Get-ChildItem $sqlDir -Filter *.sql | Sort-Object Name) {
    $db = if ($file.Name -like "00_*") { "master" } else { $Database }
    Write-Host ("Running {0,-28} on {1}/{2}" -f $file.Name, $Server, $db)
    Invoke-SqlFile $file.FullName $db
}
Write-Host "Deployment complete."
