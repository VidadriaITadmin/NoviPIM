# 06 — Bližnjice in uporabni ukazi

## Zagon lokalno

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution

dotnet run --project src\PIM.Intranet            # intranet -> http://localhost:5091
dotnet run --project workers\PIM.AutomationHost  # avtomatika (05)
dotnet build PIM.sln                             # prevedi vse
dotnet test                                      # testi (del potrebuje lokalno bazo)
```

**Visual Studio drži `bin\` zaklenjen** in `dotnet build` pade z »file is locked«. Prevedi v drugo mapo:
```powershell
dotnet build src\PIM.Intranet -p:OutDir=$env:TEMP\pim-build\
```
Datoteke v `wwwroot\` (JS, CSS) se strežejo živo — po spremembi zadošča osvežitev brskalnika (Ctrl+F5).

## Strani v intranetu

| Naslov | Kaj je tam |
|---|---|
| `/sistem` | nadzor: gostitelj, posli, zadnji zagoni, alarmi |
| `/sistem/posel/<KLJUČ>` | en posel: koraki, faze, prebrano/zapisano, sporočila |
| `/splet/umaknjeni` | samodejni umik s spleta |
| `/zajem/novi-artikli` | kandidati novih artiklov dobaviteljev |
| `/administracija/mape` | poti `EXPORT_ROOT`, `LANDING_ROOT`, dnevniki |
| `/health` | 200 = aplikacija teče (za skripte) |

## SQL — hitra pomoč

Povezava iz PowerShella (`-I` je obvezen pri spreminjanju procedur):

```powershell
sqlcmd -S "DESKTOP-TONVQHJ\MSSQLSERVER3" -E -I -d PIM -Q "SELECT TOP 5 MigrationId FROM dbo.SchemaMigration ORDER BY MigrationId DESC"
sqlcmd -S "DESKTOP-TONVQHJ\MSSQLSERVER3" -E -I -d PIM -i pot\do\poizvedbe.sql
```

(V Git Bashu dodaj pred ukaz `MSYS_NO_PATHCONV=1`, sicer Bash pokvari stikala.)

**Zadnje migracije:**
```sql
SELECT TOP 10 MigrationId, AppliedUtc FROM dbo.SchemaMigration ORDER BY MigrationId DESC;
```

**Utrip gostitelja:**
```sql
SELECT Application, HostName, HeartbeatUtc, DATEDIFF(second, HeartbeatUtc, SYSUTCDATETIME()) AS sekund FROM ops.SchedulerLease;
```

**Zadnji zagoni poslov (in kaj je padlo):**
```sql
SELECT TOP 20 JobKey, Status, StartedUtc, EndedUtc, StepsFailed, Summary
FROM ops.JobRun ORDER BY StartedUtc DESC;
```

**Največje tabele:**
```sql
SELECT TOP 15 s.name + '.' + t.name AS tabela, SUM(a.total_pages) * 8 / 1024 AS MB, MAX(p.rows) AS vrstic
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
JOIN sys.allocation_units a ON a.container_id IN (p.partition_id, p.hobt_id)
GROUP BY s.name, t.name ORDER BY MB DESC;
```

**Velikost baze in prostor na disku:**
```sql
EXEC sp_spaceused;
```

## Windows bližnjice (Win+R)

| Vpiši | Odpre |
|---|---|
| `services.msc` | storitve (PIM gostitelj avtomatike, SQL Server) |
| `taskschd.msc` | načrtovane naloge (PIM nadzor avtomatike) |
| `inetmgr` | IIS Manager (spletno mesto, application pool) |
| `eventvwr` | dnevniki Windows (padci storitev, napake IIS) |
| `ssms` | SQL Server Management Studio (če je nameščen) |
| `taskmgr` | upravitelj opravil → *Podrobnosti* za `PIM.*.exe` |

## PowerShell enovrstičnice

```powershell
Get-Process PIM.* | Select-Object Name, Id, StartTime               # kateri PIM procesi tečejo
Get-Service PIM.AutomationHost, MSSQL*                               # storitve
Get-ScheduledTask 'PIM *' | Select-Object TaskName, State            # PIM naloge
Restart-WebAppPool -Name PIM                                         # ponovni zagon intraneta v IIS
Get-ChildItem <mapa> -Recurse -File | Unblock-File                   # odblokiraj skripte iz ZIP-a
Get-Content <LOG_ROOT>\gostitelj\gostitelj-$(Get-Date -f yyyy-MM-dd).log -Tail 50 -Wait   # spremljaj dnevnik gostitelja
```

## Visual Studio

| Tipke | Kaj |
|---|---|
| Ctrl+Shift+B | prevedi rešitev |
| F5 / Ctrl+F5 | zaženi z razhroščevanjem / brez |
| Shift+F5 | ustavi (sprosti zaklenjen `bin\`) |
| Ctrl+, | poišči datoteko ali razred po imenu |
| Ctrl+Shift+F | iskanje po vseh datotekah |
| F12 / Shift+F12 | pojdi na definicijo / poišči vse uporabe |
| Ctrl+K, Ctrl+D | uredi zamike v datoteki |
