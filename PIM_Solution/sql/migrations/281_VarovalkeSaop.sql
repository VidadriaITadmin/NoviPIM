/*
  281 — Varovalke pošiljanja v SAOP.

  Uporabnik 2026-09-24: »za izvoz v SAOP treba imeti tudi neko varovalko, sploh za neaktivne artikle — da ti izpiše,
  koliko artiklov je neaktivnih«; »če je že en neaktiven, moraš opozoriti in potrebna je potrditev; uporabnik mora
  vedeti, katerim se je spremenila vrednost«; »nisem mislil, da moraš na druge strani skakati — če je artikel aktiven,
  takoj v SAOP; če je neaktiven, ti javi, toliko artiklov je neaktivnih, in se vidi seznam«; »dej mi še ostale
  varovalke notri«.

  Kako deluje: ob odobritvi (skupina, artikel, sporočilo) gre v SAOP vse, kar ni sumljivo. Sumljiva sporočila ostanejo
  v vrsti (PendingApproval); stran odobritve jih takoj pokaže s seznamom (intranet.GetSaopHeldMessages) in jih pošlje
  po potrditvi (ops.ConfirmSaopHeldMessages). Nič se ne ustavi, nič ne gre mimo človeka.

  Pravila (ops.SafeguardRule, področje SAOP; vklop, prag in najmanj artiklov nastavljivi na /varovalke):
    SAOP_NEAKTIVEN   artikel bo v SAOP neaktiven (Product.IsActive = 0/N/ne/false) — že en artikel
    SAOP_CENA_VEJICA cena ×10/×100/×1000 ali ÷ glede na trenutno ceno v SAOP (±2 %) — izgubljena ali dodana vejica
    SAOP_CENA_NIC    nova cena je 0 ali negativna
    SAOP_CENA_SKOK   cena se spremeni za več kot prag (25 %)
    SAOP_CENA_IZKLOP cena v ceniku bo izklopljena (Price.Active = false), prej je bila aktivna
    SAOP_KLJUCNO     sprememba EAN, enote mere ali skupine obstoječega artikla (vpliva na prodajo, zalogo, knjiženje)
    SAOP_MNOZICNO    isto polje v eni skupini pri vsaj pragu artiklov (100) — množična sprememba (cene imajo svoja pravila)
    SAOP_STARO       sprememba čaka v vrsti dlje od praga (7 dni) — morda ni več aktualna

  Objekti:
    ops.IsSaopDeactivation (funkcija), ops.SaopHeldMessage (pogled: sporočilo × pravilo, nepotrjeno),
    ops.SaopHeldForApproval (pogled: zadržana + ostala polja iste cene),
    out.ApproveMessage / out.ApproveItemDocument / out.ApproveOutboundBatch (preskočijo zadržana; posamična
    odobritev zadržanega vrne 52901), ops.EvaluateSaopSafeguards (preverjanje za /varovalke + zvonec),
    intranet.GetSaopHeldMessages, ops.ConfirmSaopHeldMessages, ops.OnSafeguardApproved (potrditev na /varovalke/{id}),
    out.EnqueueMessage (popravek žive definicije: deaktivacija je vedno PendingApproval).
  Potrebuje 277 (ops.SafeguardRule, ops.SafeguardFinding.SourceRef, ops.ApproveSafeguardFindings s klicem ops.OnSafeguardApproved).

  Ročni korak: ne. Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52900, N'281: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'ops.SafeguardRule', N'U') IS NULL OR COL_LENGTH(N'ops.SafeguardFinding', N'SourceRef') IS NULL
  THROW 52902, N'281 potrebuje migracijo 277 (ops.SafeguardRule, ops.SafeguardFinding.SourceRef).', 1;

/* Prva različica 281 na razvojni bazi (samo deaktivacije) je imela druga imena. */
IF OBJECT_ID(N'intranet.GetSaopDeactivations', N'P') IS NOT NULL DROP PROCEDURE intranet.GetSaopDeactivations;
IF OBJECT_ID(N'ops.ConfirmSaopDeactivations', N'P') IS NOT NULL DROP PROCEDURE ops.ConfirmSaopDeactivations;

/* --- 1) Kaj je deaktivacija ------------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER FUNCTION ops.IsSaopDeactivation (@Field nvarchar(200), @Value nvarchar(4000))
RETURNS bit
WITH SCHEMABINDING
AS
BEGIN
  /* Vrednosti, ki jih pošiljajo uvoz, kartica in popravki: 0/1, D/N, da/ne, true/false (SAOP: D/N). */
  RETURN CASE WHEN @Field = N''Product.IsActive''
                AND UPPER(LTRIM(RTRIM(@Value))) IN (N''0'', N''N'', N''NE'', N''FALSE'', N''NO'')
              THEN 1 ELSE 0 END;
END;');

/* --- 2) Pravila ------------------------------------------------------------------------------------ */
MERGE ops.SafeguardRule AS target
USING (VALUES
  (N'SAOP_NEAKTIVEN', N'Artikel bo v SAOP neaktiven', N'neaktivni v SAOP',
   N'Sprememba postavi artikel v SAOP na neaktiven: ne bo ga več v prodaji, na naročilih in v cenikih.',
   N'Preveri seznam. Če so namenoma neaktivni, potrdi. Če kateri ni, ga ne potrdi in ga na kartici spet označi kot aktivnega.',
   CONVERT(decimal(19,4), NULL), CONVERT(nvarchar(100), NULL), 1, 10),
  (N'SAOP_CENA_VEJICA', N'Cena ×10/×100 (izgubljena ali dodana vejica)', N'cena ×10/×100',
   N'Nova cena je 10-, 100- ali 1000-krat večja ali manjša od trenutne v SAOP — skoraj vedno izgubljena ali dodana decimalna vejica.',
   N'Preveri ceno v datoteki uvoza. Če je prav (npr. zamenjava enote), potrdi; sicer ne potrdi in uvozi pravilno ceno.',
   NULL, NULL, 1, 20),
  (N'SAOP_CENA_NIC', N'Cena 0', N'cena 0', N'Nova cena je 0 ali negativna.',
   N'Če je artikel res brezplačen, potrdi; sicer ne potrdi in uvozi pravo ceno.', NULL, NULL, 1, 30),
  (N'SAOP_CENA_SKOK', N'Velika sprememba cene', N'velik skok cene',
   N'Cena se spremeni za več, kot dovoljuje prag.', N'Preveri novo ceno; če je prav (nov cenik), potrdi.',
   CONVERT(decimal(19,4), 25), N'sprememba cene v %', 1, 40),
  (N'SAOP_CENA_IZKLOP', N'Cena bo izklopljena', N'izklopljena cena',
   N'Cena v ceniku bo v SAOP neaktivna — artikla po tem ceniku ne bo mogoče prodati.',
   N'Če je namenoma (artikel ne gre več po tem ceniku), potrdi.', NULL, NULL, 1, 50),
  (N'SAOP_KLJUCNO', N'Sprememba EAN, enote ali skupine', N'ključno polje',
   N'EAN, enota mere in skupina artikla vplivajo na prodajo (skener, naročila), zalogo in knjiženje.',
   N'Preveri staro in novo vrednost; če je prav, potrdi.', NULL, NULL, 1, 60),
  (N'SAOP_MNOZICNO', N'Množična sprememba istega polja', N'množična sprememba',
   N'Isto polje se v eni skupini spremeni pri veliko artiklih — ob napačnem stolpcu v Excelu gre napaka v SAOP pri vseh.',
   N'Preglej vzorec vrednosti; če je prav, potrdi vse.', CONVERT(decimal(19,4), 100), N'artiklov v skupini', 1, 70),
  (N'SAOP_STARO', N'Sprememba že dolgo čaka v vrsti', N'staro v vrsti',
   N'Sprememba čaka odobritev dlje od praga — vrednost morda ni več aktualna (medtem popravljena v SAOP ali v PIM).',
   N'Preveri, ali je še prav; če ni, sporočilo prekliči.', CONVERT(decimal(19,4), 7), N'dni v vrsti', 1, 80)
) AS source (RuleCode, Title, ShortLabel, Explanation, WhatToDo, ThresholdValue, ThresholdLabel, MinCount, SortOrder)
ON target.RuleCode = source.RuleCode
WHEN MATCHED THEN UPDATE SET Title = source.Title, ShortLabel = source.ShortLabel, Explanation = source.Explanation,
  WhatToDo = source.WhatToDo, ThresholdLabel = source.ThresholdLabel, SortOrder = source.SortOrder
WHEN NOT MATCHED THEN INSERT (RuleCode, AreaCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold,
    IsInformational, IsEnabled, ThresholdValue, ThresholdLabel, MinCount, SortOrder, UpdatedUtc, UpdatedBy)
  VALUES (source.RuleCode, N'SAOP', source.Title, source.ShortLabel, source.Explanation, source.WhatToDo, 1, 1, 0, 1,
    source.ThresholdValue, source.ThresholdLabel, source.MinCount, source.SortOrder, SYSUTCDATETIME(), N'migracija 281');

/* --- 3) Zadržana sporočila (sporočilo × pravilo) ------------------------------------------------------ */
IF OBJECT_ID(N'ops.SaopHeldDeactivation', N'V') IS NOT NULL DROP VIEW ops.SaopHeldDeactivation;

EXEC(N'CREATE OR ALTER VIEW ops.SaopHeldMessage
AS
/* 281: sporočila v vrsti za SAOP (PendingApproval), ki jih je treba pred pošiljanjem potrditi — ena vrstica na
   sporočilo in pravilo. Potrditev velja za sporočilo (prstni odtis pravilo|sporočilo): nova sprememba spet vpraša. */
WITH candidate AS
(
  SELECT message.OutboxMessageId, message.OrganizationId, message.TargetKind, message.EntityKey, message.OutboundBatchId,
    message.CreatedBy, message.CreatedUtc, message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''), Qualifier = JSON_VALUE(message.PayloadJson, N''$.qualifier'')
  FROM out.OutboxMessage AS message
  WHERE message.Status = N''PendingApproval''
),
threshold AS
(
  SELECT
    Jump = (SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''SAOP_CENA_SKOK''),
    Mass = (SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''SAOP_MNOZICNO''),
    Days = (SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''SAOP_STARO'')
),
price AS
(
  SELECT candidate.*, NewNet = TRY_CONVERT(decimal(19,4), candidate.Value), CurrentNet = current_price.Net,
    CurrentActive = current_price.IsActive
  FROM candidate
  OUTER APPLY (SELECT TOP (1) productPrice.Net, productPrice.IsActive
               FROM canon.Product AS product
               INNER JOIN canon.ProductPrice AS productPrice ON productPrice.ProductId = product.ProductId
               WHERE product.OrganizationId = candidate.OrganizationId
                 AND product.ItemID = SUBSTRING(candidate.EntityKey, CHARINDEX(N''|'', candidate.EntityKey) + 1, 450)
                 AND productPrice.PriceList = COALESCE(candidate.Qualifier, CASE WHEN CHARINDEX(N''|'', candidate.EntityKey) > 1 THEN LEFT(candidate.EntityKey, CHARINDEX(N''|'', candidate.EntityKey) - 1) END)
               ORDER BY productPrice.ValidFrom DESC) AS current_price
  WHERE candidate.TargetKind = N''SAOP_PRICE'' AND candidate.FieldSummary IN (N''Price.Net'', N''Price.Active'')
    AND CHARINDEX(N''|'', candidate.EntityKey) > 0
),
finding AS
(
  SELECT OutboxMessageId, OrganizationId, EntityKey, OutboundBatchId, CreatedBy, CreatedUtc, FieldSummary,
    RuleCode = N''SAOP_NEAKTIVEN'', OldValue = CONVERT(nvarchar(400), N''aktiven''), NewValue = CONVERT(nvarchar(400), N''neaktiven''),
    ChangeText = CONVERT(nvarchar(200), NULL)
  FROM candidate WHERE ops.IsSaopDeactivation(FieldSummary, Value) = 1

  UNION ALL
  SELECT OutboxMessageId, OrganizationId, EntityKey, OutboundBatchId, CreatedBy, CreatedUtc, FieldSummary,
    N''SAOP_CENA_NIC'', CONVERT(nvarchar(400), CurrentNet), CONVERT(nvarchar(400), NewNet), NULL
  FROM price WHERE FieldSummary = N''Price.Net'' AND NewNet <= 0

  UNION ALL
  SELECT price.OutboxMessageId, price.OrganizationId, price.EntityKey, price.OutboundBatchId, price.CreatedBy, price.CreatedUtc,
    price.FieldSummary, N''SAOP_CENA_VEJICA'', CONVERT(nvarchar(400), price.CurrentNet), CONVERT(nvarchar(400), price.NewNet),
    CONVERT(nvarchar(200), CONCAT(CASE WHEN price.NewNet > price.CurrentNet THEN NCHAR(215) ELSE NCHAR(247) END, factor.Value))
  FROM price
  CROSS APPLY (SELECT TOP (1) factor.Value FROM (VALUES (10), (100), (1000)) AS factor (Value)
               WHERE ABS(price.NewNet / NULLIF(price.CurrentNet, 0) - factor.Value) <= 0.02 * factor.Value
                  OR ABS(price.CurrentNet / NULLIF(price.NewNet, 0) - factor.Value) <= 0.02 * factor.Value
               ORDER BY factor.Value) AS factor
  WHERE price.FieldSummary = N''Price.Net'' AND price.NewNet > 0 AND price.CurrentNet > 0

  UNION ALL
  SELECT price.OutboxMessageId, price.OrganizationId, price.EntityKey, price.OutboundBatchId, price.CreatedBy, price.CreatedUtc,
    price.FieldSummary, N''SAOP_CENA_SKOK'', CONVERT(nvarchar(400), price.CurrentNet), CONVERT(nvarchar(400), price.NewNet),
    CONVERT(nvarchar(200), CONCAT(CASE WHEN price.NewNet > price.CurrentNet THEN N''+'' ELSE N'''' END,
      CONVERT(decimal(9,1), (price.NewNet - price.CurrentNet) / NULLIF(price.CurrentNet, 0) * 100), N'' %''))
  FROM price CROSS JOIN threshold
  WHERE price.FieldSummary = N''Price.Net'' AND price.NewNet > 0 AND price.CurrentNet > 0
    AND ABS(price.NewNet - price.CurrentNet) / NULLIF(price.CurrentNet, 0) * 100 > threshold.Jump
    AND NOT EXISTS (SELECT 1 FROM (VALUES (10), (100), (1000)) AS factor (Value)
                    WHERE ABS(price.NewNet / NULLIF(price.CurrentNet, 0) - factor.Value) <= 0.02 * factor.Value
                       OR ABS(price.CurrentNet / NULLIF(price.NewNet, 0) - factor.Value) <= 0.02 * factor.Value)

  UNION ALL
  SELECT OutboxMessageId, OrganizationId, EntityKey, OutboundBatchId, CreatedBy, CreatedUtc, FieldSummary,
    N''SAOP_CENA_IZKLOP'', N''aktivna'', N''neaktivna'', NULL
  FROM price WHERE FieldSummary = N''Price.Active'' AND UPPER(LTRIM(RTRIM(Value))) IN (N''FALSE'', N''0'', N''N'', N''NE'')
    AND ISNULL(CurrentActive, 1) = 1

  UNION ALL
  SELECT candidate.OutboxMessageId, candidate.OrganizationId, candidate.EntityKey, candidate.OutboundBatchId, candidate.CreatedBy,
    candidate.CreatedUtc, candidate.FieldSummary, N''SAOP_KLJUCNO'', CONVERT(nvarchar(400), history.OldValue),
    CONVERT(nvarchar(400), candidate.Value), NULL
  FROM candidate
  OUTER APPLY (SELECT TOP (1) fieldHistory.OldValue
               FROM canon.Product AS product
               INNER JOIN pim.ProductFieldHistory AS fieldHistory
                 ON fieldHistory.ProductId = product.ProductId AND fieldHistory.FieldKey = candidate.FieldSummary
               WHERE product.OrganizationId = candidate.OrganizationId AND product.ItemID = candidate.EntityKey
               ORDER BY fieldHistory.ChangeId DESC) AS history
  WHERE candidate.FieldSummary IN (N''Product.EAN'', N''Product.UoM'', N''Product.ItemGroup'')
    /* nov artikel (SAOP ga še ne pozna) ali prvi vpis polja ni sprememba */
    AND out.SaopEntityExists(candidate.OrganizationId, candidate.TargetKind, candidate.EntityKey) = 1
    AND NULLIF(LTRIM(RTRIM(history.OldValue)), N'''') IS NOT NULL

  UNION ALL
  SELECT mass.OutboxMessageId, mass.OrganizationId, mass.EntityKey, mass.OutboundBatchId, mass.CreatedBy, mass.CreatedUtc,
    mass.FieldSummary, N''SAOP_MNOZICNO'', NULL, CONVERT(nvarchar(400), mass.Value),
    CONVERT(nvarchar(200), CONCAT(mass.SameField, N'' artiklov v skupini '', mass.OutboundBatchId))
  FROM (SELECT candidate.*, SameField = COUNT(*) OVER (PARTITION BY candidate.OutboundBatchId, candidate.FieldSummary)
        FROM candidate WHERE candidate.OutboundBatchId IS NOT NULL AND candidate.TargetKind = N''SAOP_PRODUCT''
          /* novi artikli (prvi vpis v SAOP) niso množična sprememba */
          AND out.SaopEntityExists(candidate.OrganizationId, candidate.TargetKind, candidate.EntityKey) = 1) AS mass
  CROSS JOIN threshold
  WHERE mass.SameField >= threshold.Mass

  UNION ALL
  SELECT candidate.OutboxMessageId, candidate.OrganizationId, candidate.EntityKey, candidate.OutboundBatchId, candidate.CreatedBy,
    candidate.CreatedUtc, candidate.FieldSummary, N''SAOP_STARO'', NULL, CONVERT(nvarchar(400), candidate.Value),
    CONVERT(nvarchar(200), CONCAT(DATEDIFF(day, candidate.CreatedUtc, SYSUTCDATETIME()), N'' dni v vrsti''))
  FROM candidate CROSS JOIN threshold
  WHERE candidate.CreatedUtc < DATEADD(day, -CONVERT(int, threshold.Days), SYSUTCDATETIME())
),
counted AS
(
  SELECT finding.*, RuleCount = COUNT(*) OVER (PARTITION BY finding.OrganizationId, finding.RuleCode) FROM finding
)
SELECT counted.OutboxMessageId, counted.OrganizationId, counted.EntityKey, counted.OutboundBatchId, counted.CreatedBy,
  counted.CreatedUtc, counted.FieldSummary, counted.RuleCode, counted.OldValue, counted.NewValue, counted.ChangeText,
  Fingerprint = HASHBYTES(''SHA2_256'', CONCAT(counted.RuleCode, N''|'', counted.OutboxMessageId))
FROM counted
INNER JOIN ops.SafeguardRule AS safeguardRule
  ON safeguardRule.RuleCode = counted.RuleCode AND safeguardRule.IsEnabled = 1 AND safeguardRule.RequiresConfirmation = 1
WHERE counted.RuleCount >= safeguardRule.MinCount
  AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                  WHERE approval.AreaCode = N''SAOP'' AND approval.OrganizationId = counted.OrganizationId
                    AND approval.Fingerprint = HASHBYTES(''SHA2_256'', CONCAT(counted.RuleCode, N''|'', counted.OutboxMessageId)));');

/* Cena gre v SAOP kot celota (neto, DDV, velja od, aktivna v enem dokumentu): če je zadržano eno polje cene, počakajo
   tudi ostala polja iste cene — sicer bi šel DDV ali »aktivna« brez neto cene. */
EXEC(N'CREATE OR ALTER VIEW ops.SaopHeldForApproval
AS
SELECT DISTINCT held.OutboxMessageId, held.OrganizationId, held.OutboundBatchId, message.EntityType, message.EntityKey
FROM ops.SaopHeldMessage AS held
INNER JOIN out.OutboxMessage AS message ON message.OutboxMessageId = held.OutboxMessageId
UNION
SELECT sibling.OutboxMessageId, sibling.OrganizationId, sibling.OutboundBatchId, sibling.EntityType, sibling.EntityKey
FROM out.OutboxMessage AS sibling
WHERE sibling.Status = N''PendingApproval'' AND sibling.TargetKind = N''SAOP_PRICE''
  AND EXISTS (SELECT 1 FROM ops.SaopHeldMessage AS held
              INNER JOIN out.OutboxMessage AS message ON message.OutboxMessageId = held.OutboxMessageId
              WHERE message.TargetKind = N''SAOP_PRICE'' AND message.OrganizationId = sibling.OrganizationId
                AND message.EntityKey = sibling.EntityKey);');

/* --- 4) Preverjanje za /varovalke in zvonec ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateSaopSafeguards
  @OrganizationId int = NULL,   /* NULL = vsa podjetja z zadržanimi sporočili ali odprtim preverjanjem */
  @Actor nvarchar(200) = N''SISTEM'',
  @Silent bit = 0
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 281: zadržana sporočila kot preverjanje področja SAOP. Enak seznam osveži odprto preverjanje, spremenjen ustvari
     novo in staro nadomesti. Ko ni nič več zadržanega, se preverjanje zapre in opozorilo v zvoncu razreši. */
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @Result TABLE (OrganizationId int, SafeguardCheckId bigint NULL, HeldCount int);
  CREATE TABLE #All (OutboxMessageId bigint NOT NULL, OrganizationId int NOT NULL, EntityKey nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL,
    OutboundBatchId bigint NULL, CreatedBy nvarchar(200) COLLATE DATABASE_DEFAULT NULL, CreatedUtc datetime2(3) NULL,
    FieldSummary nvarchar(200) COLLATE DATABASE_DEFAULT NULL, RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
    OldValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL, NewValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    ChangeText nvarchar(200) COLLATE DATABASE_DEFAULT NULL, Fingerprint varbinary(32) NOT NULL);
  INSERT #All SELECT OutboxMessageId, OrganizationId, EntityKey, OutboundBatchId, CreatedBy, CreatedUtc, FieldSummary, RuleCode,
    OldValue, NewValue, ChangeText, Fingerprint
  FROM ops.SaopHeldMessage WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId;

  DECLARE @Organizations TABLE (OrganizationId int PRIMARY KEY);
  INSERT @Organizations (OrganizationId)
  SELECT DISTINCT OrganizationId FROM #All
  UNION
  SELECT DISTINCT OrganizationId FROM ops.SafeguardCheck
  WHERE AreaCode = N''SAOP'' AND Status = N''WAITING'' AND (@OrganizationId IS NULL OR OrganizationId = @OrganizationId);

  DECLARE @Org int = (SELECT MIN(OrganizationId) FROM @Organizations);
  WHILE @Org IS NOT NULL
  BEGIN
    DECLARE @HeldCount int = (SELECT COUNT(DISTINCT OutboxMessageId) FROM #All WHERE OrganizationId = @Org);
    DECLARE @OpenCheckId bigint =
      (SELECT TOP (1) SafeguardCheckId FROM ops.SafeguardCheck
       WHERE AreaCode = N''SAOP'' AND OrganizationId = @Org AND Status = N''WAITING'' ORDER BY SafeguardCheckId DESC);
    DECLARE @CheckId bigint = NULL;
    DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SafeguardPending|SAOP|'', @Org)), 2);

    IF @HeldCount = 0
    BEGIN
      IF @OpenCheckId IS NOT NULL
        UPDATE ops.SafeguardCheck
        SET Status = CASE WHEN EXISTS (SELECT 1 FROM ops.SafeguardFinding AS finding
                                       WHERE finding.SafeguardCheckId = @OpenCheckId AND finding.RequiresConfirmation = 1
                                         AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                                                         WHERE approval.AreaCode = N''SAOP'' AND approval.OrganizationId = @Org
                                                           AND approval.Fingerprint = finding.Fingerprint))
                          THEN N''SUPERSEDED'' ELSE N''CONFIRMED'' END,
            DecidedUtc = ISNULL(DecidedUtc, @Now), DecidedBy = ISNULL(DecidedBy, @Actor), LastEvaluatedUtc = @Now
        WHERE SafeguardCheckId = @OpenCheckId;
      UPDATE ops.Alert SET ResolvedUtc = @Now, ResolvedBy = N''SISTEM'', UpdatedUtc = @Now, UpdatedBy = N''SISTEM''
      WHERE OrganizationId = @Org AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;
    END
    ELSE
    BEGIN
      IF @OpenCheckId IS NOT NULL
         AND NOT EXISTS (SELECT Fingerprint FROM #All WHERE OrganizationId = @Org
                         EXCEPT SELECT Fingerprint FROM ops.SafeguardFinding WHERE SafeguardCheckId = @OpenCheckId AND RequiresConfirmation = 1)
         AND NOT EXISTS (SELECT finding.Fingerprint FROM ops.SafeguardFinding AS finding
                         WHERE finding.SafeguardCheckId = @OpenCheckId AND finding.RequiresConfirmation = 1
                           AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                                           WHERE approval.AreaCode = N''SAOP'' AND approval.OrganizationId = @Org
                                             AND approval.Fingerprint = finding.Fingerprint)
                         EXCEPT SELECT Fingerprint FROM #All WHERE OrganizationId = @Org)
      BEGIN
        UPDATE ops.SafeguardCheck SET EvaluationCount = EvaluationCount + 1, LastEvaluatedUtc = @Now WHERE SafeguardCheckId = @OpenCheckId;
        SET @CheckId = @OpenCheckId;
      END
      ELSE
      BEGIN
        DECLARE @Headline nvarchar(400) =
          (SELECT LEFT(STRING_AGG(CONVERT(nvarchar(max), CONCAT(safeguardRule.ShortLabel, N'': '', counted.Messages)), N'', '')
                    WITHIN GROUP (ORDER BY safeguardRule.SortOrder), 400)
           FROM (SELECT RuleCode, Messages = COUNT(*) FROM #All WHERE OrganizationId = @Org GROUP BY RuleCode) AS counted
           INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = counted.RuleCode);
        DECLARE @Findings int = (SELECT COUNT(*) FROM #All WHERE OrganizationId = @Org);
        BEGIN TRANSACTION;
        INSERT ops.SafeguardCheck (AreaCode, OrganizationId, Status, SubjectLabel, RowCountValue, FindingCount, ConfirmCount,
          HeldCount, Headline, CreatedUtc, LastEvaluatedUtc, CreatedBy)
        VALUES (N''SAOP'', @Org, N''WAITING'', N''pošiljanje v SAOP'', @HeldCount, @Findings, @Findings, @HeldCount,
          @Headline, @Now, @Now, @Actor);
        SET @CheckId = SCOPE_IDENTITY();
        UPDATE ops.SafeguardCheck SET Status = N''SUPERSEDED'', SupersededByCheckId = @CheckId
        WHERE AreaCode = N''SAOP'' AND OrganizationId = @Org AND Status = N''WAITING'' AND SafeguardCheckId <> @CheckId;
        INSERT ops.SafeguardFinding (SafeguardCheckId, RuleCode, ItemID, ProductId, FieldCode, FieldLabel, OldValue, NewValue,
          ChangeText, ReasonFields, ReasonActor, ReasonUtc, RequiresConfirmation, Fingerprint, SourceRef)
        SELECT @CheckId, held.RuleCode, itemKey.ItemID, product.ProductId, held.FieldSummary, held.FieldSummary,
          held.OldValue, held.NewValue, LEFT(held.ChangeText, 100),
          /* Od kod: vir skupine, opomba, številka skupine (prikaz na /varovalke/{id}). */
          LEFT(CONCAT(CASE batch.Source WHEN N''EXCEL'' THEN N''uvoz iz Excela'' WHEN N''CARD'' THEN N''kartica artikla''
                                        WHEN N''BULK'' THEN N''popravek'' ELSE ISNULL(batch.Source, N''vrsta za SAOP'') END,
                      CASE WHEN batch.Note IS NOT NULL THEN CONCAT(N'' · '', batch.Note) END,
                      CASE WHEN held.OutboundBatchId IS NOT NULL THEN CONCAT(N'' · skupina '', held.OutboundBatchId) END), 1000),
          held.CreatedBy, held.CreatedUtc, 1, held.Fingerprint, held.OutboxMessageId
        FROM #All AS held
        LEFT JOIN out.OutboundBatch AS batch ON batch.OutboundBatchId = held.OutboundBatchId
        CROSS APPLY (SELECT ItemID = CONVERT(nvarchar(100), CASE WHEN CHARINDEX(N''|'', held.EntityKey) > 0
                                                               THEN SUBSTRING(held.EntityKey, CHARINDEX(N''|'', held.EntityKey) + 1, 450)
                                                               ELSE held.EntityKey END)) AS itemKey
        OUTER APPLY (SELECT TOP (1) candidate.ProductId FROM canon.Product AS candidate
                     WHERE candidate.OrganizationId = @Org AND (candidate.ItemID = itemKey.ItemID OR candidate.EAN = itemKey.ItemID)
                     ORDER BY CASE WHEN candidate.ItemID = itemKey.ItemID THEN 0 ELSE 1 END) AS product
        WHERE held.OrganizationId = @Org;
        COMMIT;
      END;

      DECLARE @Title nvarchar(300) = LEFT(CONCAT(N''SAOP: '', @HeldCount, N'' sprememb čaka potrditev — '',
        (SELECT Headline FROM ops.SafeguardCheck WHERE SafeguardCheckId = @CheckId)), 300);
      EXEC ops.UpsertAlert @OrganizationId = @Org, @Pipeline = N''VAROVALKA:SAOP'', @AlertKind = N''SafeguardPending'',
        @Severity = N''Warning'', @DedupKey = @DedupKey, @Title = @Title,
        @PayloadSummaryRedacted = N''Te spremembe se v SAOP ne pošljejo, dokler jih kdo ne potrdi (seznam je na strani odobritve in na Varovalkah). Ostale gredo normalno.'',
        @Actor = @Actor;
    END;

    INSERT @Result (OrganizationId, SafeguardCheckId, HeldCount) VALUES (@Org, @CheckId, @HeldCount);
    SET @Org = (SELECT MIN(OrganizationId) FROM @Organizations WHERE OrganizationId > @Org);
  END;

  IF @Silent = 0 SELECT OrganizationId, SafeguardCheckId, HeldCount FROM @Result ORDER BY OrganizationId;
END;');

/* --- 5) Seznam in potrditev na mestu odobritve ---------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSaopHeldMessages
  @OutboundBatchId bigint = NULL,
  @OrganizationId int = NULL,
  @EntityKeysJson nvarchar(max) = NULL   /* ["šifra", ...] — artikli, ki jih stran odobrava; NULL = vsi */
AS
BEGIN
  SET NOCOUNT ON;
  SELECT held.OutboxMessageId, held.OrganizationId, OrganizationName = COALESCE(organization.Name, CONCAT(N''podjetje '', held.OrganizationId)),
    held.RuleCode, RuleTitle = safeguardRule.Title, RuleShort = safeguardRule.ShortLabel, RuleOrder = safeguardRule.SortOrder,
    ItemID = itemKey.ItemID, PriceList = CASE WHEN CHARINDEX(N''|'', held.EntityKey) > 0 THEN LEFT(held.EntityKey, CHARINDEX(N''|'', held.EntityKey) - 1) END,
    Title = COALESCE(NULLIF(title.Value, N''''), itemKey.ItemID), held.FieldSummary, held.OldValue, held.NewValue, held.ChangeText,
    Source = CONCAT(CASE batch.Source WHEN N''EXCEL'' THEN N''uvoz iz Excela'' WHEN N''CARD'' THEN N''kartica artikla''
                                      WHEN N''BULK'' THEN N''popravek'' ELSE ISNULL(batch.Source, N''vrsta za SAOP'') END,
                    CASE WHEN batch.Note IS NOT NULL THEN CONCAT(N'' · '', batch.Note) END),
    held.OutboundBatchId, held.CreatedBy, held.CreatedUtc
  FROM ops.SaopHeldMessage AS held
  INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = held.RuleCode
  CROSS APPLY (SELECT ItemID = CONVERT(nvarchar(100), CASE WHEN CHARINDEX(N''|'', held.EntityKey) > 0
                                                         THEN SUBSTRING(held.EntityKey, CHARINDEX(N''|'', held.EntityKey) + 1, 450)
                                                         ELSE held.EntityKey END)) AS itemKey
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = held.OrganizationId
  LEFT JOIN out.OutboundBatch AS batch ON batch.OutboundBatchId = held.OutboundBatchId
  OUTER APPLY (SELECT TOP (1) product.ProductId FROM canon.Product AS product
               WHERE product.OrganizationId = held.OrganizationId AND (product.ItemID = itemKey.ItemID OR product.EAN = itemKey.ItemID)
               ORDER BY CASE WHEN product.ItemID = itemKey.ItemID THEN 0 ELSE 1 END) AS product
  OUTER APPLY (SELECT TOP (1) text.Value FROM canon.ProductText AS text
               WHERE text.ProductId = product.ProductId AND text.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'') AND text.Lang = N''sl''
               ORDER BY CASE WHEN text.TextType = N''TITLE_ERP'' THEN 0 ELSE 1 END) AS title
  WHERE (@OutboundBatchId IS NULL OR held.OutboundBatchId = @OutboundBatchId)
    AND (@OrganizationId IS NULL OR held.OrganizationId = @OrganizationId)
    AND (@EntityKeysJson IS NULL OR itemKey.ItemID IN (SELECT value FROM OPENJSON(@EntityKeysJson)) OR held.EntityKey IN (SELECT value FROM OPENJSON(@EntityKeysJson)))
  ORDER BY safeguardRule.SortOrder, held.OrganizationId, itemKey.ItemID, held.FieldSummary;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.ConfirmSaopHeldMessages
  @OutboxMessageIdsJson nvarchar(max),   /* [id, ...] — sporočila, ki jih je uporabnik videl na seznamu in potrdil */
  @Actor nvarchar(200),
  @Approve bit = 1                       /* 1 = hkrati odobri za pošiljanje */
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52905, N''Potrditev potrebuje uporabnika.'', 1;
  DECLARE @Ids TABLE (OutboxMessageId bigint PRIMARY KEY);
  INSERT @Ids SELECT DISTINCT TRY_CONVERT(bigint, value) FROM OPENJSON(@OutboxMessageIdsJson) WHERE TRY_CONVERT(bigint, value) IS NOT NULL;

  BEGIN TRANSACTION;
  INSERT ops.SafeguardApproval (AreaCode, OrganizationId, Fingerprint, RuleCode, ItemID, FieldCode, OldValue, NewValue,
    SafeguardCheckId, ApprovedUtc, ApprovedBy, Note)
  SELECT N''SAOP'', held.OrganizationId, held.Fingerprint, held.RuleCode, LEFT(held.EntityKey, 100), held.FieldSummary,
    held.OldValue, held.NewValue, NULL, SYSUTCDATETIME(), @Actor, N''potrjeno ob odobritvi''
  FROM ops.SaopHeldMessage AS held
  WHERE held.OutboxMessageId IN (SELECT OutboxMessageId FROM @Ids);
  DECLARE @Confirmed int = (SELECT COUNT(*) FROM @Ids);
  IF @Approve = 1
    UPDATE out.OutboxMessage
    SET Status = N''Pending'', ApprovedUtc = SYSUTCDATETIME(), ApprovedBy = @Actor, NextAttemptUtc = SYSUTCDATETIME(), UpdatedUtc = SYSUTCDATETIME()
    WHERE Status = N''PendingApproval''
      AND (OutboxMessageId IN (SELECT OutboxMessageId FROM @Ids)
           /* ostala polja iste cene gredo skupaj s potrjeno ceno */
           OR (TargetKind = N''SAOP_PRICE'' AND EXISTS (SELECT 1 FROM out.OutboxMessage AS confirmed
                                                       WHERE confirmed.OutboxMessageId IN (SELECT OutboxMessageId FROM @Ids)
                                                         AND confirmed.TargetKind = N''SAOP_PRICE'' AND confirmed.OrganizationId = out.OutboxMessage.OrganizationId
                                                         AND confirmed.EntityKey = out.OutboxMessage.EntityKey)))
      AND OutboxMessageId NOT IN (SELECT OutboxMessageId FROM ops.SaopHeldForApproval);
  COMMIT;
  EXEC ops.EvaluateSaopSafeguards @Actor = @Actor, @Silent = 1;
  SELECT Confirmed = @Confirmed;
END;');

/* --- 6) Potrditev na /varovalke/{id} spusti izbrana sporočila --------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ops.OnSafeguardApproved
  @SafeguardCheckId bigint,
  @AreaCode nvarchar(50),
  @OrganizationId int,
  @ApprovedUtc datetime2(3),
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  /* Klic iz ops.ApproveSafeguardFindings (277), v njeni transakciji. SAOP: sporočilo, ki nima več nepotrjenega
     pravila, je odobreno za pošiljanje. */
  IF @AreaCode <> N''SAOP'' RETURN;
  UPDATE message
  SET Status = N''Pending'', ApprovedUtc = @ApprovedUtc, ApprovedBy = @Actor, NextAttemptUtc = @ApprovedUtc, UpdatedUtc = @ApprovedUtc
  FROM out.OutboxMessage AS message
  WHERE message.Status = N''PendingApproval''
    AND message.OutboxMessageId IN (SELECT finding.SourceRef FROM ops.SafeguardFinding AS finding
                                    INNER JOIN ops.SafeguardApproval AS approval
                                      ON approval.AreaCode = N''SAOP'' AND approval.OrganizationId = @OrganizationId
                                     AND approval.Fingerprint = finding.Fingerprint AND approval.SafeguardCheckId = @SafeguardCheckId
                                     AND approval.ApprovedUtc = @ApprovedUtc
                                    WHERE finding.SafeguardCheckId = @SafeguardCheckId)
    AND message.OutboxMessageId NOT IN (SELECT OutboxMessageId FROM ops.SaopHeldForApproval);
  /* ostala polja iste cene gredo skupaj s potrjeno ceno */
  UPDATE sibling
  SET Status = N''Pending'', ApprovedUtc = @ApprovedUtc, ApprovedBy = @Actor, NextAttemptUtc = @ApprovedUtc, UpdatedUtc = @ApprovedUtc
  FROM out.OutboxMessage AS sibling
  WHERE sibling.Status = N''PendingApproval'' AND sibling.TargetKind = N''SAOP_PRICE''
    AND EXISTS (SELECT 1 FROM out.OutboxMessage AS confirmed
                WHERE confirmed.TargetKind = N''SAOP_PRICE'' AND confirmed.Status = N''Pending'' AND confirmed.ApprovedUtc = @ApprovedUtc
                  AND confirmed.OrganizationId = sibling.OrganizationId AND confirmed.EntityKey = sibling.EntityKey)
    AND sibling.OutboxMessageId NOT IN (SELECT OutboxMessageId FROM ops.SaopHeldForApproval);
END;');

/* --- 7) Odobritev v vrsti preskoči zadržana sporočila ---------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE out.ApproveMessage @OutboxMessageId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  /* 281: sumljiva sprememba gre v SAOP šele po potrditvi (seznam na strani odobritve). */
  IF EXISTS (SELECT 1 FROM ops.SaopHeldForApproval WHERE OutboxMessageId = @OutboxMessageId)
  BEGIN
    DECLARE @HeldOrganizationId int = (SELECT OrganizationId FROM out.OutboxMessage WHERE OutboxMessageId = @OutboxMessageId);
    EXEC ops.EvaluateSaopSafeguards @OrganizationId = @HeldOrganizationId, @Actor = @Actor, @Silent = 1;
    THROW 52901, N''Ta sprememba gre v SAOP šele, ko potrdiš, da je prav (seznam sprememb, ki čakajo potrditev).'', 1;
  END;
  BEGIN TRAN;
  UPDATE out.OutboxMessage SET Status=N''Pending'',ApprovedUtc=SYSUTCDATETIME(),ApprovedBy=@Actor,NextAttemptUtc=SYSUTCDATETIME(),UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId AND Status=N''PendingApproval'';
  IF @@ROWCOUNT<>1 BEGIN ROLLBACK; THROW 51002, N''Sporočila ni mogoče odobriti.'', 1; END;
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.ApproveItemDocument
  @OrganizationId int, @EntityType nvarchar(100), @EntityKey nvarchar(200), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Held TABLE (OutboxMessageId bigint PRIMARY KEY);
  INSERT @Held SELECT DISTINCT OutboxMessageId FROM ops.SaopHeldForApproval
  WHERE OrganizationId = @OrganizationId AND EntityType = @EntityType AND EntityKey = @EntityKey;
  DECLARE @HeldCount int = (SELECT COUNT(*) FROM @Held);
  BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Pending'', ApprovedUtc = SYSUTCDATETIME(), ApprovedBy = @Actor,
      NextAttemptUtc = SYSUTCDATETIME(), UpdatedUtc = SYSUTCDATETIME()
  WHERE OrganizationId = @OrganizationId AND EntityType = @EntityType AND EntityKey = @EntityKey
    AND Status = N''PendingApproval''
    /* 281: sumljive spremembe čakajo potrditev. */
    AND OutboxMessageId NOT IN (SELECT OutboxMessageId FROM @Held);
  DECLARE @Odobrenih int = @@ROWCOUNT;
  COMMIT;
  IF @HeldCount > 0 EXEC ops.EvaluateSaopSafeguards @OrganizationId = @OrganizationId, @Actor = @Actor, @Silent = 1;
  IF @Odobrenih = 0 AND @HeldCount > 0
    THROW 52901, N''Ta sprememba gre v SAOP šele, ko potrdiš, da je prav (seznam sprememb, ki čakajo potrditev).'', 1;
  IF @Odobrenih = 0 THROW 51005, N''Za ta artikel ni cakajocih sprememb za odobritev.'', 1;
  SELECT Odobrenih = @Odobrenih, Zadrzanih = @HeldCount;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.ApproveOutboundBatch @OutboundBatchId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Held TABLE (OutboxMessageId bigint PRIMARY KEY, OrganizationId int);
  INSERT @Held SELECT DISTINCT OutboxMessageId, OrganizationId FROM ops.SaopHeldForApproval WHERE OutboundBatchId = @OutboundBatchId;
  DECLARE @HeldCount int = (SELECT COUNT(*) FROM @Held);
  DECLARE @HeldOrganizationId int = (SELECT TOP (1) OrganizationId FROM @Held);
  BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Pending'', ApprovedUtc = SYSUTCDATETIME(), ApprovedBy = @Actor,
      NextAttemptUtc = SYSUTCDATETIME(), UpdatedUtc = SYSUTCDATETIME()
  WHERE OutboundBatchId = @OutboundBatchId AND Status = N''PendingApproval''
    /* 281: sumljive spremembe ostanejo v vrsti do potrditve; ostalo gre naprej. */
    AND OutboxMessageId NOT IN (SELECT OutboxMessageId FROM @Held);
  DECLARE @Odobrenih int = @@ROWCOUNT;
  UPDATE out.OutboundBatch SET ClosedUtc = NULL WHERE OutboundBatchId = @OutboundBatchId;
  COMMIT;
  IF @HeldCount > 0 EXEC ops.EvaluateSaopSafeguards @OrganizationId = @HeldOrganizationId, @Actor = @Actor, @Silent = 1;
  SELECT Odobrenih = @Odobrenih, Zadrzanih = @HeldCount;
END;');

/* --- 8) out.EnqueueMessage: deaktivacija nikoli ni samodejno odobrena ------------------------------- */
DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.EnqueueMessage'));
IF @Definition IS NULL THROW 52903, N'281: out.EnqueueMessage ne obstaja.', 1;
IF CHARINDEX(N'IsSaopDeactivation', @Definition) = 0
BEGIN
  DECLARE @Anchor nvarchar(200) = N'IF @Status IS NULL THROW 51001, ''Integracijski profil ni omogocen.'', 1;';
  IF CHARINDEX(@Anchor, @Definition) = 0 THROW 52904, N'281: sidro v out.EnqueueMessage ni najdeno — definicija se je spremenila.', 1;
  SET @Definition = REPLACE(@Definition, @Anchor, @Anchor + NCHAR(13) + NCHAR(10)
    + N'  /* 281: deaktivacija artikla v SAOP vedno čaka potrditev, tudi pri samodejni odobritvi profila. */' + NCHAR(13) + NCHAR(10)
    + N'  IF ops.IsSaopDeactivation(@Field, @Value) = 1 SET @Status = N''PendingApproval'';');
  SET @Definition = STUFF(@Definition, CHARINDEX(N'CREATE', @Definition), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC sys.sp_executesql @Definition;
END;
