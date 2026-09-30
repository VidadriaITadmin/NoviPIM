/* 311_HitriPogledZadrzanihSaop — rezervirano za nalogo #46 (david, 2026-09-30 06:43). */
/*
  311 — Pogled ops.SaopHeldMessage brez 60-sekundnega preračuna (naloga #46; pomaga tudi #51).

  Pravilo SAOP_KLJUCNO (sprememba EAN, enote ali skupine artikla, ki jo SAOP že pozna) išče prejšnjo vrednost
  polja v pim.ProductFieldHistory (~2,7 mio. vrstic). Pogoj ni vseboval podjetja, zato SQL ni mogel uporabiti
  indeksa IX_PimProductFieldHistory_Product (OrganizationId, ProductId) in je za vsako čakajočo spremembo
  nazaj bral celo zgodovino: 20 mio. branj, ~60 s ob vsakem branju pogleda (pasica na /outbound, /cene,
  /saop/artikli, /izvozi/mnozicno, odobritev serije). Dodan je pogoj fieldHistory.OrganizationId =
  product.OrganizationId — zgodovina izdelka je vedno v podjetju izdelka (preverjeno: 0 izjem), zato je izid enak.
  Na razvojni bazi: ista poizvedba 7 ms namesto ~60 s.

  Spremenjeno: ops.SaopHeldMessage (CREATE OR ALTER VIEW, ista definicija kot v 281 + en pogoj).
  SAOP: nič (samo branje; potrditev in pošiljanje ostaneta enaka). Ročni korak: ne. Ponovljivo: da.
  Razveljavitev: ponovno zaženi definicijo pogleda iz 281.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53100, N'311: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'ops.SaopHeldMessage', N'V') IS NULL
  THROW 53101, N'311: najprej mora biti uveljavljena 281 (ops.SaopHeldMessage).', 1;

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
                /* 311: podjetje vodi iskanje po IX_PimProductFieldHistory_Product (OrganizationId, ProductId) —
                   brez njega je SQL za vsako spremembo nazaj bral celo zgodovino (20 mio. branj, ~60 s) */
                AND fieldHistory.OrganizationId = product.OrganizationId
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
