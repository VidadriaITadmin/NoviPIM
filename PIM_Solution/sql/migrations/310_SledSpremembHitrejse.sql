/*
  310 — Sled sprememb (/sistem/sled) spet hitra — naloga #44.

  Težava: intranet.GetUserActivityTrail (172) je ob vsakem odprtju strani prebrala celo tabelo
  pim.ProductFieldHistory (2,7 milijona vrstic, OldValue/NewValue nvarchar(800)), jo z Hash Match
  povezala s ProductChangeBatch in šele na koncu razvrstila za TOP (@Take). Indeksa po času ni bilo.
  Ko je zgodovina v sunkih zrasla (22. 9. in 29. 9. po ~60.000 vrstic na dan), je stran postala
  počasna (77–108 s na hladnem predpomnilniku) ali pa je padla na časovni omejitvi.

  Popravek:
  1. Indeks IX_PimProductFieldHistory_Changed na (ChangedAtUtc DESC) z vsemi stolpci, ki jih sled
     potrebuje za filter in opis (brez OldValue/NewValue — ti se preberejo samo za @Take vrstic).
  2. Procedura ima enak vmesnik, iste stolpce, istih 7 virov in isto iskanje kot 172. Razlika:
     vsaka veja sama vzame največ @Take najnovejših vrstic (filter uporabnika in iskanja je ZNOTRAJ
     veje, zato iskanje ne izpusti zadetkov), šele nato se veje združijo in razvrstijo. OPTION(RECOMPILE),
     ker se načrt za »7 dni, brez iskanja« in »leto, z iskanjem« bistveno razlikuje.
     Polja izdelkov gredo v dveh korakih (#polje: najprej ChangeId, nato vrednosti za največ @Take vrstic);
     pri iskanju se LIKE za uporabnika računa enkrat na paket, za opis enkrat na par polje/lastnik,
     po vrsticah samo za šifro izdelka (glej komentar v proceduri).

  Rezultat je enak kot prej (prvih @Take vrstic po času; pri popolnoma enakem času je vrstni red
  kot prej nedoločen).

  Ročni korak: na produkciji uveljavi izven urnikov uvozov. Gradnja indeksa na 2,7 milijona vrstic
  traja od nekaj sekund do nekaj minut. Na izdajah z ONLINE (Enterprise/Developer/Azure) gre ONLINE,
  drugje (Standard/Express) je med gradnjo pisanje v pim.ProductFieldHistory blokirano.
  Pot nazaj: ponovno uveljaviti razdelek 8 iz 172_AdminConsole.sql in DROP INDEX
  IX_PimProductFieldHistory_Changed ON pim.ProductFieldHistory.
  Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

IF UNICODE(N'č') <> 269
  THROW 53100, N'310: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.ProductFieldHistory', N'U') IS NULL OR OBJECT_ID(N'pim.ProductChangeBatch', N'U') IS NULL
  THROW 53101, N'310 potrebuje pim.ProductFieldHistory in pim.ProductChangeBatch.', 1;

/* --- 1 — indeks po času -------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory')
                  AND name = N'IX_PimProductFieldHistory_Changed')
BEGIN
  /* 3 = Enterprise/Developer/Evaluation, 5 = Azure SQL Database, 8 = Managed Instance: ti znajo ONLINE. */
  DECLARE @Online bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) IN (3, 5, 8) THEN 1 ELSE 0 END;
  DECLARE @Sql nvarchar(max) = N'CREATE NONCLUSTERED INDEX IX_PimProductFieldHistory_Changed
    ON pim.ProductFieldHistory (ChangedAtUtc DESC)
    INCLUDE (ChangeBatchId, OrganizationId, ItemID, FieldKey, Owner)'
    + CASE WHEN @Online = 1 THEN N' WITH (ONLINE = ON);' ELSE N';' END;
  EXEC (@Sql);
END;

/* --- 2 — procedura: TOP po veji, nato združitev ---------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetUserActivityTrail
  @Days int = 7,
  @Actor nvarchar(200) = NULL,
  @Search nvarchar(200) = NULL,
  @Take int = 300
AS
BEGIN
  SET NOCOUNT ON;
  IF @Days IS NULL OR @Days < 1 SET @Days = 7;
  IF @Days > 365 SET @Days = 365;
  IF @Take IS NULL OR @Take < 1 SET @Take = 300;
  IF @Take > 2000 SET @Take = 2000;

  DECLARE @Od datetime2(3) = DATEADD(day, -@Days, SYSUTCDATETIME());
  DECLARE @Vzorec nvarchar(210) = CASE WHEN @Search IS NULL OR LTRIM(RTRIM(@Search)) = N'''' THEN NULL
                                       ELSE N''%'' + LTRIM(RTRIM(@Search)) + N''%'' END;

  /*
     Polja izdelkov (2,7 milijona vrstic) gredo v dveh korakih: najprej samo ChangeId najnovejših
     ustreznih vrstic po indeksu IX_PimProductFieldHistory_Changed, nato OldValue/NewValue samo zanje.

     Iskanje: vrstica ustreza, ce vzorec vsebuje uporabnik (paket.ChangedBy), sifra (ItemID) ali opis
     »Polje <FieldKey> (<Owner>)« — enako kot v 172. Da se LIKE ne racuna na milijonih vrstic:
       - uporabnik: vzorec se preveri enkrat na paket (#paket, ~10.000 vrstic);
       - opis: vzorec se preveri enkrat na par (FieldKey, Owner) (#opis, nekaj deset vrstic);
         FieldKey dobimo s preskakovanjem po indeksu IX_PimProductFieldHistory_Field, Owner je po
         CK_PimFieldOwnership_Owner eden od PIM/SAOP/SHARED (+ morebitni obstojeci v pim.FieldOwnership);
       - sifra: edini LIKE po vrsticah, samo na ozkem indeksu.
     Vsak od treh nacinov vzame TOP (@Take) najnovejsih, UNION jih zdruzi brez podvojitev.
  */
  CREATE TABLE #polje (ChangeId bigint NOT NULL PRIMARY KEY);

  IF @Vzorec IS NULL AND @Actor IS NULL
  BEGIN
    INSERT #polje (ChangeId)
    SELECT TOP (@Take) zgodovina.ChangeId
      FROM pim.ProductFieldHistory zgodovina
      JOIN pim.ProductChangeBatch paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId
     WHERE zgodovina.ChangedAtUtc >= @Od
     ORDER BY zgodovina.ChangedAtUtc DESC
    OPTION (RECOMPILE);
  END
  ELSE
  BEGIN
    CREATE TABLE #paket (ChangeBatchId bigint NOT NULL PRIMARY KEY, Ujema bit NOT NULL);
    INSERT #paket (ChangeBatchId, Ujema)
    SELECT paket.ChangeBatchId, CASE WHEN @Vzorec IS NULL OR paket.ChangedBy LIKE @Vzorec THEN 1 ELSE 0 END
      FROM pim.ProductChangeBatch paket
     WHERE @Actor IS NULL OR paket.ChangedBy = @Actor
    OPTION (RECOMPILE);

    CREATE TABLE #opis (FieldKey nvarchar(128) COLLATE DATABASE_DEFAULT NOT NULL,
                        Owner nvarchar(16) COLLATE DATABASE_DEFAULT NOT NULL,
                        PRIMARY KEY (FieldKey, Owner));
    IF @Vzorec IS NOT NULL
    BEGIN
      /* Preskakovanje po indeksu IX_PimProductFieldHistory_Field: en iskalni skok na razlicen FieldKey. */
      DECLARE @Kljuc nvarchar(128) = (SELECT MIN(h.FieldKey) FROM pim.ProductFieldHistory h);
      DECLARE @Varovalo int = 0;
      WHILE @Kljuc IS NOT NULL AND @Varovalo < 100000
      BEGIN
        INSERT #opis (FieldKey, Owner)
        SELECT @Kljuc, lastnik.Owner
          FROM (SELECT v.Owner FROM (VALUES (N''PIM''), (N''SAOP''), (N''SHARED'')) v(Owner)
                UNION
                SELECT o.Owner FROM pim.FieldOwnership o) lastnik
         WHERE CONCAT(N''Polje '', @Kljuc, N'' ('', lastnik.Owner, N'')'') LIKE @Vzorec
           AND NOT EXISTS (SELECT 1 FROM #opis x WHERE x.FieldKey = @Kljuc AND x.Owner = lastnik.Owner);
        SET @Kljuc = (SELECT MIN(h.FieldKey) FROM pim.ProductFieldHistory h WHERE h.FieldKey > @Kljuc);
        SET @Varovalo += 1;
      END;
    END;

    /* Vsak nacin posebej in samo, ce ima kaj iskati: prazen #paket/#opis ne sme sprozit pregleda vseh vrstic. */
    CREATE TABLE #kandidat (ChangeId bigint NOT NULL PRIMARY KEY WITH (IGNORE_DUP_KEY = ON), OccurredUtc datetime2(7) NOT NULL);

    IF EXISTS (SELECT 1 FROM #paket WHERE Ujema = 1)
      INSERT #kandidat (ChangeId, OccurredUtc)
      SELECT TOP (@Take) zgodovina.ChangeId, zgodovina.ChangedAtUtc
        FROM pim.ProductFieldHistory zgodovina
        JOIN #paket paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId AND paket.Ujema = 1
       WHERE zgodovina.ChangedAtUtc >= @Od
       ORDER BY zgodovina.ChangedAtUtc DESC
      OPTION (RECOMPILE);

    IF @Vzorec IS NOT NULL AND EXISTS (SELECT 1 FROM #paket)
      INSERT #kandidat (ChangeId, OccurredUtc)
      SELECT TOP (@Take) zgodovina.ChangeId, zgodovina.ChangedAtUtc
        FROM pim.ProductFieldHistory zgodovina
        JOIN #paket paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId
       WHERE zgodovina.ChangedAtUtc >= @Od
         AND zgodovina.ItemID LIKE @Vzorec
       ORDER BY zgodovina.ChangedAtUtc DESC
      OPTION (RECOMPILE);

    IF EXISTS (SELECT 1 FROM #opis) AND EXISTS (SELECT 1 FROM #paket)
      INSERT #kandidat (ChangeId, OccurredUtc)
      SELECT TOP (@Take) zgodovina.ChangeId, zgodovina.ChangedAtUtc
        FROM pim.ProductFieldHistory zgodovina
        JOIN #paket paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId
        JOIN #opis o ON o.FieldKey = zgodovina.FieldKey AND o.Owner = zgodovina.Owner
       WHERE zgodovina.ChangedAtUtc >= @Od
       ORDER BY zgodovina.ChangedAtUtc DESC
      OPTION (RECOMPILE);

    INSERT #polje (ChangeId)
    SELECT TOP (@Take) kandidat.ChangeId FROM #kandidat kandidat ORDER BY kandidat.OccurredUtc DESC;
  END;

  /*
     Ostali viri so majhni. Vsaka veja vrne največ @Take najnovejših vrstic, ki ze ustrezajo uporabniku
     in iskanju; filter mora biti v veji, ker bi TOP pred filtrom pri iskanju izpustil zadetke.
     Opis (Summary) je v filtru zapisan enako kot v izpisu, da iskanje isce po istem besedilu.
  */
  WITH sled AS
  (
    /* Polja izdelkov: izbrane vrstice iz #polje. */
    SELECT zgodovina.ChangedAtUtc AS OccurredUtc,
           paket.ChangedBy AS Actor,
           N''PRODUCT_FIELD'' AS ActionCode,
           N''Izdelek'' AS EntityType,
           zgodovina.ItemID AS EntityKey,
           zgodovina.OrganizationId,
           CONCAT(N''Polje '', zgodovina.FieldKey, N'' ('', zgodovina.Owner, N'')'') AS Summary,
           zgodovina.OldValue,
           zgodovina.NewValue,
           N''pim.ProductFieldHistory'' AS SourceTable
      FROM #polje izbrano
      JOIN pim.ProductFieldHistory zgodovina ON zgodovina.ChangeId = izbrano.ChangeId
      JOIN pim.ProductChangeBatch paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId

    UNION ALL

    /* Dejanja intraneta, ki drugod ne pustijo vrstice (migracija 172). */
    SELECT dejanje.OccurredUtc, dejanje.Actor, dejanje.ActionCode, dejanje.EntityType, dejanje.EntityKey,
           dejanje.OrganizationId, dejanje.Summary, dejanje.OldValue, dejanje.NewValue, dejanje.SourceTable
      FROM (SELECT TOP (@Take) d.OccurredUtc, d.Actor, d.ActionCode, d.EntityType, d.EntityKey,
                   d.OrganizationId, d.Summary, d.OldValue, d.NewValue, N''ops.UserActivity'' AS SourceTable
              FROM ops.UserActivity d
             WHERE d.OccurredUtc >= @Od
               AND (@Actor IS NULL OR d.Actor = @Actor)
               AND (@Vzorec IS NULL OR d.Actor LIKE @Vzorec OR d.EntityKey LIKE @Vzorec OR d.Summary LIKE @Vzorec)
             ORDER BY d.OccurredUtc DESC) dejanje

    UNION ALL

    /* Alarmi: potrditev in razresitev sta zapisani v svojih stolpcih. */
    SELECT potrditev.*
      FROM (SELECT TOP (@Take) a.AcknowledgedUtc AS OccurredUtc, a.AcknowledgedBy AS Actor,
                   N''ALERT_ACK'' AS ActionCode, N''Alarm'' AS EntityType,
                   CAST(a.AlertId AS nvarchar(300)) AS EntityKey, a.OrganizationId,
                   CONCAT(N''Potrdil alarm: '', a.Title) AS Summary,
                   CAST(NULL AS nvarchar(800)) AS OldValue, CAST(NULL AS nvarchar(800)) AS NewValue,
                   N''ops.Alert'' AS SourceTable
              FROM ops.Alert a
             WHERE a.AcknowledgedUtc >= @Od AND a.AcknowledgedBy IS NOT NULL
               AND (@Actor IS NULL OR a.AcknowledgedBy = @Actor)
               AND (@Vzorec IS NULL OR a.AcknowledgedBy LIKE @Vzorec
                    OR CAST(a.AlertId AS nvarchar(300)) LIKE @Vzorec
                    OR CONCAT(N''Potrdil alarm: '', a.Title) LIKE @Vzorec)
             ORDER BY a.AcknowledgedUtc DESC) potrditev

    UNION ALL

    SELECT razresitev.*
      FROM (SELECT TOP (@Take) a.ResolvedUtc AS OccurredUtc, a.ResolvedBy AS Actor,
                   N''ALERT_RESOLVE'' AS ActionCode, N''Alarm'' AS EntityType,
                   CAST(a.AlertId AS nvarchar(300)) AS EntityKey, a.OrganizationId,
                   CONCAT(N''Razresil alarm: '', a.Title) AS Summary,
                   CAST(NULL AS nvarchar(800)) AS OldValue, CAST(NULL AS nvarchar(800)) AS NewValue,
                   N''ops.Alert'' AS SourceTable
              FROM ops.Alert a
             WHERE a.ResolvedUtc >= @Od AND a.ResolvedBy IS NOT NULL
               AND (@Actor IS NULL OR a.ResolvedBy = @Actor)
               AND (@Vzorec IS NULL OR a.ResolvedBy LIKE @Vzorec
                    OR CAST(a.AlertId AS nvarchar(300)) LIKE @Vzorec
                    OR CONCAT(N''Razresil alarm: '', a.Title) LIKE @Vzorec)
             ORDER BY a.ResolvedUtc DESC) razresitev

    UNION ALL

    /* Odobritve odhodnih sporocil v SAOP. */
    SELECT odobritev.*
      FROM (SELECT TOP (@Take) s.ApprovedUtc AS OccurredUtc, s.ApprovedBy AS Actor,
                   N''OUTBOX_APPROVE'' AS ActionCode, N''Odhodno sporocilo'' AS EntityType,
                   s.EntityKey, s.OrganizationId,
                   CONCAT(N''Odobril '', s.Operation, N'' za '', s.EntityType) AS Summary,
                   CAST(NULL AS nvarchar(800)) AS OldValue,
                   LEFT(ISNULL(s.FieldSummary, N''''), 400) AS NewValue,
                   N''out.OutboxMessage'' AS SourceTable
              FROM out.OutboxMessage s
             WHERE s.ApprovedUtc >= @Od AND s.ApprovedBy IS NOT NULL
               AND (@Actor IS NULL OR s.ApprovedBy = @Actor)
               AND (@Vzorec IS NULL OR s.ApprovedBy LIKE @Vzorec OR s.EntityKey LIKE @Vzorec
                    OR CONCAT(N''Odobril '', s.Operation, N'' za '', s.EntityType) LIKE @Vzorec)
             ORDER BY s.ApprovedUtc DESC) odobritev

    UNION ALL

    /* Urniki: tabela hrani samo zadnjo spremembo, zato je tu ena vrstica na razpored. */
    SELECT urnik.*
      FROM (SELECT TOP (@Take) r.UpdatedUtc AS OccurredUtc, r.UpdatedBy AS Actor,
                   N''SCHEDULE_UPDATE'' AS ActionCode, N''Urnik'' AS EntityType,
                   r.Pipeline AS EntityKey, r.OrganizationId,
                   CONCAT(N''Urnik '', r.Pipeline, CASE WHEN r.IsEnabled = 1 THEN N'' vklopljen'' ELSE N'' izklopljen'' END) AS Summary,
                   CAST(NULL AS nvarchar(800)) AS OldValue,
                   CONCAT(r.IntervalSeconds / 60, N'' min'') AS NewValue,
                   N''ops.ScheduleProfile'' AS SourceTable
              FROM ops.ScheduleProfile r
             WHERE r.UpdatedUtc >= @Od
               AND (@Actor IS NULL OR r.UpdatedBy = @Actor)
               AND (@Vzorec IS NULL OR r.UpdatedBy LIKE @Vzorec OR r.Pipeline LIKE @Vzorec
                    OR CONCAT(N''Urnik '', r.Pipeline, CASE WHEN r.IsEnabled = 1 THEN N'' vklopljen'' ELSE N'' izklopljen'' END) LIKE @Vzorec)
             ORDER BY r.UpdatedUtc DESC) urnik

    UNION ALL

    /* Poslovni register B2B. */
    SELECT revizija.*
      FROM (SELECT TOP (@Take) v.ChangedUtc AS OccurredUtc, v.ChangedBy AS Actor, v.ActionCode, v.EntityType,
                   v.EntityKey, v.OrganizationId,
                   CONCAT(v.ActionCode, N'' na '', v.EntityType) AS Summary,
                   CAST(NULL AS nvarchar(800)) AS OldValue, CAST(NULL AS nvarchar(800)) AS NewValue,
                   N''b2b.AuditLog'' AS SourceTable
              FROM b2b.AuditLog v
             WHERE v.ChangedUtc >= @Od
               AND (@Actor IS NULL OR v.ChangedBy = @Actor)
               AND (@Vzorec IS NULL OR v.ChangedBy LIKE @Vzorec OR v.EntityKey LIKE @Vzorec
                    OR CONCAT(v.ActionCode, N'' na '', v.EntityType) LIKE @Vzorec)
             ORDER BY v.ChangedUtc DESC) revizija
  )
  SELECT TOP (@Take) sled.OccurredUtc, sled.Actor, sled.ActionCode, sled.EntityType, sled.EntityKey,
         sled.OrganizationId, podjetje.Name AS OrganizationName, sled.Summary, sled.OldValue, sled.NewValue,
         sled.SourceTable
    FROM sled
    LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = sled.OrganizationId
   WHERE sled.OccurredUtc IS NOT NULL
   ORDER BY sled.OccurredUtc DESC
  OPTION (RECOMPILE);
END;');
