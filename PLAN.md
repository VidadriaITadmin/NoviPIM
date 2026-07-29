# PLAN — F0: temelji PIM sistema

## Meja izvedbe
Izvedena bo izključno faza F0 iz `_SPEC/PIM_Hermes_Navodila_Gradnja_Od_Nic.md`. F1–F9 se ne bodo začele.

Ciljni imenik je `PIM_Solution/`; `PIM_test/` ostane nespremenjen.

## Koraki

1. Ustvarim samostojno rešitev .NET 8 v `PIM_Solution/` s predpisano strukturo:
   `src/`, `workers/`, `sql/migrations/`, `sql/registry-seed/`, `deploy/`, `tests/`, `_SPEC/`, `docs/`.
   Dodam samo skeletne .NET 8 projekte, potrebne za preverljiv zagon, brez poslovne logike in brez virov.

2. Zgradim migracijski okvir za MSSQL:
   - oštevilčene idempotentne SQL migracije;
   - `dbo.SchemaMigration` z vsebinskim hashom in časom uporabe;
   - zagonski PowerShell skript, ki migracije serializira, preveri hash že uporabljenih migracij in uporabi manjkajoče po vrstnem redu v transakciji;
   - nastanek shem `raw`, `map`, `canon`, `val`, `pim`, `out`, `ops`, `dbo`, `sec`.

3. Z eno ali več oštevilčenimi migracijami ustvarim samo F0 podatkovne objekte:
   - `ops.PipelineRun`, `ops.PipelineStepLog`, `ops.DeadLetterQueue`, `ops.ErrorLog`, `ops.Heartbeat`;
   - `dbo.OrganizationConfig` ter začetne vrstice DEMO, IQLighting, Vidadria in Ediito;
   - podporne indekse in omejitve za varno ponovno izvajanje;
   - pomožni proceduri za centralno napako in karanteno.

4. Dodam vzorec enotnega proceduralnega skeleta (`XACT_ABORT`, predpogoji, TRY/TRANSACTION/CATCH, centralni zapis napake in ponovni `THROW`) ter avtomatiziran SQL-test za njegovo delovanje.

5. Dodam konfiguracijo brez skrivnosti:
   - sledena `appsettings.Development.json` in `appsettings.Production.json` s praznimi oziroma referenčnimi vrednostmi;
   - ignorirane lokalne konfiguracije in sledeni primer;
   - jasen neuspeh zagona migracij, če ni podan zunanji connection string.

6. Preverim F0:
   - statične/preizkusne teste .NET in `npm test`/`npm run lint` iz nadrejenega repozitorija;
   - če dobim razvojni MSSQL connection string, dejanski zagon iz nič in še en idempotentni zagon;
   - preverbo shem, tabel, začetnih organizacij in pomožnih procedur;
   - `git diff --check` in pregled, da ni skrivnosti.

7. Po uspehu zapišem `TEST_REPORT` in vrstico v `PROGRESS.md`. Nato se ustavim in čakam na ukaz `nadaljuj` za F1.

## Potrebni podatki za polni DoD
Za dejanski dokaz postavitve baze 2× potrebujem razvojni MSSQL connection string (lahko ga podate kot začasno okoljsko spremenljivko; ne bo zapisan v repo). V trenutnem okolju ni nameščen `sqlcmd` niti ni dosegljiv lokalni MSSQL strežnik.

## Ne bo izvedeno v F0
Ni zajemanja virov, nobenih SAOP/FTP/HTTP dostopov, transformacij, kanoničnih tabel, validacije, PIM-kataloga, izvoza, UI-ja ali IIS objave. To so kasnejše faze.
