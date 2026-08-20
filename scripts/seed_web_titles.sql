/*
  Napolni spletne nazive (WEB_TITLE) za izdelke, ki so ze presli ERP_L1
  validacijo, a jim manjka spletni naziv in zato padejo na WEB_B2C.

  NI migracija. To so podatki o izdelkih, ne shema, zato se ne sme samodejno
  izvesti na vsakem okolju. Zaganja se rocno in je idempotenten:
  pise samo tja, kjer vrednosti se ni, obstojecih nikoli ne prepise.

  Vira sta oba resnicna, nobena vrednost ni izmisljena:
    WEB_TITLE.sl  <- canon.ProductText TITLE_ERP.sl   (slovenski naziv iz SAOP)
    WEB_TITLE.en  <- map.ExtractedValue product_name  (angleski naziv iz NW XML)

  OPOZORILO o kakovosti: slovenski ERP nazivi niso enolicni. NW.9448 (1 m),
  NW.9451 in NW.9452 (2 m) imajo vsi TITLE_ERP "PROFILE tracnica NT1N", ceprav
  so fizicno razlicni izdelki - angleski naziv to locuje ("PROFILE TRACK 1 M"
  proti "2 M"). Isto velja za TURDA III / TURDA VII. Za spletno trgovino je to
  premalo; ti nazivi so uporabna zacetna vrednost, ne koncna.

  Razveljavitev: WEB_TITLE zapisi, ki jih naredi ta skript, so natanko tisti,
  kjer je Value enak pripadajocemu TITLE_ERP.sl oziroma NW product_name.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Target TABLE (ProductId bigint PRIMARY KEY);

/* Samo izdelki, ki so ze VALID po ERP_L1 - ozek, ponovljiv obseg. */
INSERT @Target (ProductId)
SELECT DISTINCT state.ProductId
FROM val.ProductValidationState state
INNER JOIN val.ValidationProfile profile
  ON profile.ValidationProfileId = state.ValidationProfileId
WHERE state.Status = N'VALID'
  AND profile.ProfileCode = N'ERP_L1';

DECLARE @ScopeCount int = (SELECT COUNT(*) FROM @Target);
PRINT CONCAT(N'Izdelkov v obsegu: ', @ScopeCount);

/* --- WEB_TITLE.sl iz TITLE_ERP.sl --------------------------------------- */

INSERT canon.ProductText (ProductId, Lang, TextType, Value)
SELECT erp.ProductId, N'sl', N'WEB_TITLE', erp.Value
FROM canon.ProductText erp
INNER JOIN @Target target ON target.ProductId = erp.ProductId
WHERE erp.TextType = N'TITLE_ERP'
  AND erp.Lang = N'sl'
  AND NULLIF(LTRIM(RTRIM(erp.Value)), N'') IS NOT NULL
  AND NOT EXISTS
  (
    SELECT 1 FROM canon.ProductText existing
    WHERE existing.ProductId = erp.ProductId
      AND existing.Lang = N'sl'
      AND existing.TextType = N'WEB_TITLE'
  );

PRINT CONCAT(N'Dodanih WEB_TITLE.sl: ', @@ROWCOUNT);

/* --- WEB_TITLE.en iz NW XML product_name -------------------------------- */

/* Zapisi so bili izvleceni, ko je preslikava se kazala na mrtvo tarco
   Unsupported.F5Probe (migracija 041 jo je preusmerila na WEB_TITLE.en).
   Povezava na izdelek gre prek EAN v istem zapisu XML. */

WITH NwName AS
(
  SELECT
    product.ProductId,
    name.Value,
    ROW_NUMBER() OVER (PARTITION BY product.ProductId ORDER BY name.ExtractedValueId DESC) AS Recency
  FROM map.ExtractedValue name
  INNER JOIN map.ExtractedValue ean
    ON ean.InboxId = name.InboxId
   AND ean.RecordOrdinal = name.RecordOrdinal
   AND ean.TargetFieldCode = N'Product.EAN'
  INNER JOIN canon.Product product
    ON product.EAN = LTRIM(RTRIM(ean.Value))
  WHERE name.TargetFieldCode IN (N'Unsupported.F5Probe', N'ProductText.WEB_TITLE.en')
    AND NULLIF(LTRIM(RTRIM(name.Value)), N'') IS NOT NULL
)
INSERT canon.ProductText (ProductId, Lang, TextType, Value)
SELECT nw.ProductId, N'en', N'WEB_TITLE', LTRIM(RTRIM(nw.Value))
FROM NwName nw
INNER JOIN @Target target ON target.ProductId = nw.ProductId
WHERE nw.Recency = 1
  AND NOT EXISTS
  (
    SELECT 1 FROM canon.ProductText existing
    WHERE existing.ProductId = nw.ProductId
      AND existing.Lang = N'en'
      AND existing.TextType = N'WEB_TITLE'
  );

PRINT CONCAT(N'Dodanih WEB_TITLE.en: ', @@ROWCOUNT);
