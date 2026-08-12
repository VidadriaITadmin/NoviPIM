# NoviPIM

PIM sistem za ~200.000 artiklov štirih podjetij. .NET 9, Blazor Server, MS SQL.

**To je edini delovni repozitorij.** Koda je v `PIM_Solution\`.

## Za agente

Preberi **[`AGENTS.md`](AGENTS.md)** — to so edina pravila. Koordinator (Hermes)
prebere še [`docs/HERMES.md`](docs/HERMES.md).

## Zagon

```powershell
# build
dotnet build PIM_Solution\PIM.sln

# testi
dotnet test PIM_Solution\PIM.sln --no-restore

# migracije proti razvojni bazi PIM
dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify
```

Intranet teče na `http://127.0.0.1:5199`.

> Če build pade z `MSB3027 ... file is locked`, teče intranet. Ustavi proces
> `PIM.Intranet` in ponovi. To ni napaka v kodi.

## Zemljevid

| Pot | Vsebina |
|---|---|
| `PIM_Solution\src\` | domenski projekti in intranet |
| `PIM_Solution\workers\` | 10 workerjev |
| `PIM_Solution\sql\migrations\` | oštevilčene migracije, samo dodajanje |
| `PIM_Solution\tests\` | 33+ testnih projektov |
| `docs\` | baza, workerji, intranet, izvozi, namestitev, E2E |
| `TASKBOARD.md` | kdo kaj dela |
| `STATUS.md` | kje je sistem |

## Sosednje mape (izven repozitorija)

| Pot | Kaj |
|---|---|
| `..\PIM_test` | star referenčni sistem, **samo branje** |
| `..\_arhiv` | zastarelo, ni vir resnice |
| `..\Dokumentacija` | PDF-ji in ročne beležke |
| `..\Backups` | varnostne kopije |
