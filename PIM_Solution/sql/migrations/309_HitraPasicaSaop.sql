/* 309_HitraPasicaSaop — rezervirano za nalogo #46 (david, 2026-09-30 06:24). */
/*
  309 — Pasica »spremembe za SAOP čakajo potrditev« brez 60-sekundnega čakanja (naloga #46).

  intranet.GetSaopHeldMessages (281) je naziv artikla iskal z enim OUTER APPLY na canon.Product s pogojem
  (ItemID = šifra OR EAN = šifra). Zaradi OR je SQL za vsako zadržano sporočilo pregledal vse izdelke
  (~196 tisoč na razvojni bazi); pri 632 sporočilih IQ je procedura tekla 60-68 s, stran /outbound pa je
  čakala nanjo. Zdaj sta iskanji ločeni: najprej po šifri, nato (samo če šifre ni) po EAN — obe po indeksu.
  Izpis je enak kot prej (isti stolpci, isti vrstni red, zadetek po šifri ima prednost pred EAN).

  Spremenjeno: intranet.GetSaopHeldMessages (CREATE OR ALTER, isti parametri in izhodi kot v 281).
  Pogled ops.SaopHeldMessage ostane nespremenjen. SAOP: nič (samo branje). Ročni korak: ne. Ponovljivo: da.
  Razveljavitev: ponovno zaženi definicijo procedure iz 281.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53090, N'309: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'ops.SaopHeldMessage', N'V') IS NULL
  THROW 53091, N'309: najprej mora biti uveljavljena 281 (ops.SaopHeldMessage).', 1;

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
  /* 309: najprej po šifri (UQ_CanonProduct_OrganizationItem), šele nato po EAN (IX_CanonProduct_OrganizationEan) —
     prej en APPLY z OR, ki je za vsako vrstico pregledal vse izdelke. */
  OUTER APPLY (SELECT TOP (1) byItem.ProductId FROM canon.Product AS byItem
               WHERE byItem.OrganizationId = held.OrganizationId AND byItem.ItemID = itemKey.ItemID) AS byItem
  OUTER APPLY (SELECT TOP (1) byEan.ProductId FROM canon.Product AS byEan
               WHERE byItem.ProductId IS NULL AND byEan.OrganizationId = held.OrganizationId AND byEan.EAN = itemKey.ItemID
               ORDER BY byEan.ProductId) AS byEan
  CROSS APPLY (SELECT ProductId = COALESCE(byItem.ProductId, byEan.ProductId)) AS product
  OUTER APPLY (SELECT TOP (1) text.Value FROM canon.ProductText AS text
               WHERE text.ProductId = product.ProductId AND text.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'') AND text.Lang = N''sl''
               ORDER BY CASE WHEN text.TextType = N''TITLE_ERP'' THEN 0 ELSE 1 END) AS title
  WHERE (@OutboundBatchId IS NULL OR held.OutboundBatchId = @OutboundBatchId)
    AND (@OrganizationId IS NULL OR held.OrganizationId = @OrganizationId)
    AND (@EntityKeysJson IS NULL OR itemKey.ItemID IN (SELECT value FROM OPENJSON(@EntityKeysJson)) OR held.EntityKey IN (SELECT value FROM OPENJSON(@EntityKeysJson)))
  ORDER BY safeguardRule.SortOrder, held.OrganizationId, itemKey.ItemID, held.FieldSummary;
END;');
