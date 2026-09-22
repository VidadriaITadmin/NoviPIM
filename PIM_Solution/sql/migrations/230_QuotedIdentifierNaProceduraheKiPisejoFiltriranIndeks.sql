/*
  230 — QUOTED_IDENTIFIER OFF na map.ApplyValueTransforms (in treh starejsih ops.* procedurah)
  lomi UPDATE proti tabeli s filtriranim indeksom (napaka 1934).

  --- Kaj je bilo narobe ------------------------------------------------------------------------

  Od 17. 9. 2026 ob 13:34 (5 minut po zadnjem uspesnem teku) je SAOP_PRICES padal za vsa stiri
  podjetja identicno, na strani /sistem (zavihek Postopki) viden kot:

    "UPDATE failed because the following SET options have incorrect settings: 'QUOTED_IDENTIFIER'.
     Verify that SET options are correct for use with indexed views and/or indexes on computed
     columns and/or filtered indexes and/or query notifications and/or XML data type methods
     and/or spatial index operations."

  To je SQL Server napaka 1934: seja, ki izvaja UPDATE, ima QUOTED_IDENTIFIER izklopljen, ciljna
  tabela pa ima filtriran indeks (ali indeksiran pogled/computed stolpec/XML metodo), ki zahteva
  vklopljen. Vzrok, potrjen na DAVID\MSSQL19 prek sys.sql_modules:

    map.ApplyValueTransforms   uses_quoted_identifier = 0   spremenjeno 2026-09-17 13:34:38

  Veriga:
    1. Migracija 218 (isti dan) je na map.ExtractedValue dodala filtriran indeks
       IX_ExtractedValue_Identity (... WHERE TargetFieldCode IN (N'Product.ItemID', N'Record.ItemID',
       N'Product.EAN')). Od takrat vsak UPDATE/INSERT/DELETE na tej tabeli zahteva QUOTED_IDENTIFIER
       ON za CELO sejo, ne le za vrstice, ki jih indeks dejansko zajema.
    2. Migracija 220 je map.ApplyValueTransforms spremenila mimo obicajnega vzorca v tem repozitoriju
       (EXEC(N'CREATE OR ALTER PROCEDURE ...')): prebrala je OBJECT_DEFINITION, vrinila novo vejo
       (HttpsPrefix220) in jo pognala nazaj prek sys.sp_executesql - BREZ predhodnega
       SET QUOTED_IDENTIFIER ON (za razliko od 194/195, ki to eksplicitno naredita pred vsako
       CREATE OR ALTER PROCEDURE). ALTER PROCEDURE si zapomni QUOTED_IDENTIFIER seje, ki ga IZVEDE,
       ne seje, ki jo kasneje klice - karkoli je pognalo 220 (sqlcmd brez -I ima to privzeto
       izklopljeno; glej opombo v Invoke-PendingMigrations.ps1: "brez tega nekatere procedure v tem
       repozitoriju padejo z napako 1934 pri UPDATE. Ne odstranjuj -I."), je proceduro trajno
       zapeklo z izklopljeno nastavitvijo.
    3. map.ApplyValueTransforms UPDATE-a prav map.ExtractedValue (RawValue, Value) - zato od 218+220
       naprej pade vsak klic, ki doseze vsaj eno vrstico s Value IS NOT NULL in aktivnim korakom v
       map.FieldTransform. SAOP_PRICES je prvi opazen, ker ima GetPrices vecino poljem s koraki
       (npr. NUMBER); po istem mehanizmu tvegata tudi SAOP_PRODUCTS in GENERIC_XML za polja z
       aktivnim korakom - oba kliceta isto proceduro (PIM.KatalogWorker, PIM.XmlFileWorker).

  Ista poizvedba (sys.sql_modules WHERE uses_quoted_identifier = 0) je razkrila se tri starejse
  procedure v isti pomoti, spremenjene ze 2. 9. 2026 - torej pred 218/220 in neodvisno od te napake:
  ops.BeginRun, ops.AbandonOrphanRuns, ops.RecordRunCounts. Doslej niso padle, ker tabele, ki jih
  pisejo (ops.PipelineRun, ops.IntegrationHealth), (se) nimajo filtriranega indeksa - a so pod istim
  tveganjem ob naslednjem, zato jih popravi ista migracija.

  --- Popravek ------------------------------------------------------------------------------------

  Za vse stiri procedure: SET QUOTED_IDENTIFIER ON (v tem batchu, pred sp_executesql), nato isto
  telo (OBJECT_DEFINITION -> CREATE prepisan v ALTER -> sp_executesql, isti vzorec kot 220, tokrat
  s pravilno SET opcijo pred klicem). Brez vsebinske spremembe kode - popravi se izkljucno
  metapodatek uses_quoted_identifier (0 -> 1). Migracija je ponovljiva: ce je procedura ze pravilna,
  jo preskoci.

  Migrator ne pozna GO (opomba v 061/220), zato je cel popravek en batch; DECLARE ... TABLE +
  kurzor namesto stirih skoraj identicnih blokov, da se ista napaka ne ponovi s copy-paste.
*/

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Objekti TABLE (ObjectName sysname PRIMARY KEY);
INSERT @Objekti (ObjectName) VALUES
  (N'map.ApplyValueTransforms'),
  (N'ops.BeginRun'),
  (N'ops.AbandonOrphanRuns'),
  (N'ops.RecordRunCounts');

DECLARE @Ime sysname, @Telo nvarchar(max);
DECLARE popravek CURSOR LOCAL FAST_FORWARD FOR SELECT ObjectName FROM @Objekti;
OPEN popravek;
FETCH NEXT FROM popravek INTO @Ime;
WHILE @@FETCH_STATUS = 0
BEGIN
  IF OBJECT_ID(@Ime) IS NULL THROW 52300, N'230: pricakovan objekt ne obstaja.', 1;

  IF (SELECT m.uses_quoted_identifier FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID(@Ime)) = 0
  BEGIN
    SET @Telo = OBJECT_DEFINITION(OBJECT_ID(@Ime));
    IF @Telo IS NULL THROW 52301, N'230: definicije objekta ni bilo mogoce prebrati.', 1;
    SET @Telo = N'ALTER ' + SUBSTRING(@Telo, CHARINDEX(N'PROCEDURE', @Telo), 2147483647);
    EXEC sys.sp_executesql @Telo;
  END;

  FETCH NEXT FROM popravek INTO @Ime;
END;
CLOSE popravek;
DEALLOCATE popravek;

/* --- Dokaz ---------------------------------------------------------------------------------- */
IF EXISTS
(
  SELECT 1
  FROM sys.sql_modules m
  INNER JOIN sys.objects o ON o.object_id = m.object_id
  WHERE m.uses_quoted_identifier = 0
    AND CONCAT(SCHEMA_NAME(o.schema_id), N'.', o.name) IN
      (N'map.ApplyValueTransforms', N'ops.BeginRun', N'ops.AbandonOrphanRuns', N'ops.RecordRunCounts')
)
  THROW 52302, N'230: vsaj ena procedura se vedno nima QUOTED_IDENTIFIER ON.', 1;
