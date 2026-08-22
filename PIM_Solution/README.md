# PIM_Solution

Za usklajeno delo Hermesa, Claude Code in Codexa glej [docs/AGENTSKA_ORKESTRACIJA.md](docs/AGENTSKA_ORKESTRACIJA.md). Nadrejena pravila ostajajo v `..\AGENTS.md`.

F0 vsebuje samo temelje: .NET 8 rešitev, oštevilčene MSSQL migracije, nadzorno sobo `ops.*`, začetne organizacije in skupni transakcijski vzorec za pisalne procedure.

## Lokalni zagon migracij

Connection string se ne shranjuje v repozitorij. Nastavite ga kot okoljsko spremenljivko in zaženite:

```powershell
$env:PIM_CONNECTION_STRING = '<lokalni connection string>'
.\deploy\Apply-Migrations.ps1
.\deploy\Apply-Migrations.ps1 -VerifyOnly
```

Migrator pridobi transakcijsko aplikacijsko ključavnico, preveri SHA-256 že uporabljenih migracij in uporabi manjkajoče skripte po vrstnem redu. Sprememba že uporabljene migracije je zavrnjena; nova sprememba zahteva novo oštevilčeno migracijo.

`appsettings.Development.json` in `appsettings.Production.json` ne vsebujeta skrivnosti. Lokalni `appsettings.Local.json` je ignoriran in ima sledeni primer `appsettings.Local.example.json`.

F0 ne vsebuje zajemanja virov, poslovne transformacije, validacije, PIM-kataloga, izvozov ali uporabniškega vmesnika.
