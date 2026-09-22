# 02 — Migracije baze

Migracije so datoteke `PIM_Solution\sql\migrations\NNN_Opis.sql`. Katere so že uveljavljene, piše v
tabeli `dbo.SchemaMigration` v bazi. Skripta uveljavi **samo manjkajoče** — varno jo je pognati večkrat.

## Lokalno (razvojni računalnik)

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution\sql\migrations
$cs = "Server=DESKTOP-TONVQHJ\MSSQLSERVER3;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"

# 1. samo pogled - nič ne spremeni
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PendingMigrations.ps1 -MigrationsPath $PWD -ConnectionString $cs -Status

# 2. uveljavi manjkajoče
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PendingMigrations.ps1 -MigrationsPath $PWD -ConnectionString $cs
```

Oba ukaza sta tudi v `Kako_pognati.txt` v isti mapi.

**Zakaj `-MigrationsPath $PWD`:** v Windows PowerShell 5.1 je privzeta pot pri zagonu z `-File` prazna in
skripta pade z »empty string«. **Zakaj `-ExecutionPolicy Bypass`:** sicer lahko PowerShell zavrne
nepodpisano skripto.

### Kaj pomeni izpis `-Status`

| Stanje | Pomen | Ukrep |
|---|---|---|
| `Applied` | že uveljavljena | nič |
| `Pending` | še ni uveljavljena | pogon brez `-Status` jo uveljavi |
| `CHANGED` / `SPREMENJENA` | uveljavljena, a datoteka je od takrat drugačna | skripta jo preskoči; ne poganjaj je znova na silo (glej 07_Tezave) |

## Na strežniku

1. **Backup** (SSMS, kot SQL administrator): odpri `PIM_Solution\deploy\Backup-PIM.sql`, popravi samo
   `@BackupFile` (datum v imenu) in poženi. Skripta naredi `COPY_ONLY` backup in ga preveri.
2. Mapo `sql\migrations` iz nove različice (git pull / ZIP / objava) imej na strežniku.
3. Enaka ukaza kot lokalno, z **strežniško** povezavo:
   ```powershell
   cd C:\pot\do\NoviPIM\PIM_Solution\sql\migrations
   $cs = "Server=IME-SQL-STREZNIKA;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PendingMigrations.ps1 -MigrationsPath $PWD -ConnectionString $cs -Status
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PendingMigrations.ps1 -MigrationsPath $PWD -ConnectionString $cs
   ```
   Na strežniku mora biti nameščen `sqlcmd` (SQL Server Command Line Utilities).
4. Preveri `-Status` še enkrat: `Pending` naj bo 0.

**Brez sqlcmd / brez izvorne kode:** prenosljiv paket (`deploy\New-PortableRelease.ps1`) vsebuje
`database\PIM.Migrator.exe` in `Apply-PimDatabase.ps1` — postopek v `deploy\PORTABLE_RELEASE.md`, korak 4.

## Pravila

- Migracija se v `sqlcmd` vedno poganja z `-I` (skripta to naredi sama). Brez tega nekatere procedure
  padejo z napako 1934.
- Že uveljavljene `.sql` datoteke **ne spreminjaj** — naredi novo migracijo z naslednjo številko.
- Pred novo migracijo preveri najvišjo številko v mapi **in** v bazi:
  ```sql
  SELECT TOP 5 MigrationId FROM dbo.SchemaMigration ORDER BY MigrationId DESC;
  ```
- Če migracija pade na polovici: datoteke pred njo iz istega zagona **ostanejo** uveljavljene (vsaka
  teče v svoji seji). Popravi vzrok in poženi znova — nadaljuje pri tisti, ki je padla.
- Dolge migracije (velike tabele) poganjaj izven delovnega časa in z ustavljenim AutomationHostom
  (05_AutomationHost.md), da se ne zaklepata.
