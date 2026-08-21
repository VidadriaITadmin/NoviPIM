/*
  Merilo hitrosti za map.ProcessRawInbox.

  Zakaj obstaja: trditev "8 artiklov/s" je bila izmerjena na zivem zajemu, ki ga ni
  mogoce ponoviti na zahtevo. To merilo je ponovljivo in ne potrebuje SAOP.

  Kaj naredi:
    1. postavi svoj konektor BENCH_A3 s svojimi preslikavami (12 polj na zapis),
    2. postavi eno vrstico raw.Inbox z @N zapisi v map.ExtractedValue,
    3. pozene map.ProcessRawInbox in izmeri cas,
    4. prebere, kaj je nastalo (dokaz, da ni meril praznega teka),
    5. za sabo pobrise vse svoje vrstice in preveri, da jih je ostalo 0.

  Brise samo vrstice, ki jih je ustvarilo samo (AGENTS.md #4.1): omejeno na
  OrganizationId = @OrgId in ItemID LIKE 'BENCH-A3-%' oziroma na svoj InboxId.

  Zagon:
    sqlcmd -S localhost\MSSQLSERVER3 -d PIM -E -C -v N=2000 -i Bench-ProcessRawInbox.sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_WARNINGS ON;

DECLARE @N int = $(N);
DECLARE @OrgId int = 1;
DECLARE @Src nvarchar(200) = N'BENCH_A3';
DECLARE @Entity nvarchar(200) = N'BenchItem';
DECLARE @RunId uniqueidentifier = NEWID();

/* ---------- 0. odstrani morebitne ostanke prejsnjega zagona ---------- */
DECLARE @Mine TABLE(ProductId bigint PRIMARY KEY);
INSERT @Mine(ProductId)
SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrgId AND ItemID LIKE N'BENCH-A3-%';

DECLARE @MyBatches TABLE(ChangeBatchId bigint PRIMARY KEY);
INSERT @MyBatches(ChangeBatchId)
SELECT DISTINCT h.ChangeBatchId FROM pim.ProductFieldHistory h WHERE h.ProductId IN (SELECT ProductId FROM @Mine);

DELETE FROM val.ProductIssue           WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM stock.Position             WHERE MatchedProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductCommercial    WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductPrice         WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductMedia         WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductCategory      WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductAttribute     WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductText          WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM pim.ProductFieldHistory    WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM pim.ProductChangeBatch     WHERE ChangeBatchId IN (SELECT ChangeBatchId FROM @MyBatches)
  AND NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory h WHERE h.ChangeBatchId = pim.ProductChangeBatch.ChangeBatchId);
DELETE FROM canon.Product              WHERE ProductId IN (SELECT ProductId FROM @Mine);

DELETE FROM map.UnmappedValue
WHERE ExtractedValueId IN
(
  SELECT v.ExtractedValueId FROM map.ExtractedValue v
  INNER JOIN raw.Inbox i ON i.InboxId = v.InboxId
  WHERE i.SourceCode = @Src
);
DELETE FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE SourceCode = @Src);
DELETE FROM raw.Inbox WHERE SourceCode = @Src;
DELETE FROM ops.PipelineRun WHERE Pipeline = N'BENCH_A3';
DELETE FROM map.Watermark WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.FieldMapping WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.EntityMapping WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.SourceConnector WHERE SourceCode = @Src;

/* ---------- 1. konektor ---------- */
DECLARE @ConnId int =
  (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src AND OrganizationId = @OrgId);

IF @ConnId IS NULL
BEGIN
  INSERT map.SourceConnector(SourceCode, OrganizationId, ConnectorType, IsActive, CanCreateProducts)
  VALUES(@Src, @OrgId, N'BENCH', 1, 1);
  SET @ConnId = SCOPE_IDENTITY();
END
ELSE
  UPDATE map.SourceConnector SET IsActive = 1, CanCreateProducts = 1 WHERE SourceConnectorId = @ConnId;

MERGE map.EntityMapping AS target
USING (VALUES(@Entity, N'/bench/item')) AS source(EntityType, RecordXPath)
  ON target.SourceConnectorId = @ConnId AND target.EntityType = source.EntityType
WHEN NOT MATCHED THEN
  INSERT(SourceConnectorId, EntityType, RecordXPath, IsActive)
  VALUES(@ConnId, source.EntityType, source.RecordXPath, 1);

MERGE map.FieldMapping AS target
USING (VALUES
  (N'bench/ItemID',       N'Product.ItemID',                  CONVERT(bit, 1)),
  (N'bench/EAN',          N'Product.EAN',                     CONVERT(bit, 0)),
  (N'bench/UoM',          N'Product.UoM',                     CONVERT(bit, 0)),
  (N'bench/Manufacturer', N'Product.Manufacturer',            CONVERT(bit, 0)),
  (N'bench/ItemGroup',    N'Product.ItemGroup',               CONVERT(bit, 0)),
  (N'bench/WebPublish',   N'Product.WebPublish',              CONVERT(bit, 0)),
  (N'bench/Name',         N'ProductText.WEB_TITLE.sl',             CONVERT(bit, 0)),
  (N'bench/Attr',         N'ProductAttribute.BenchAttr',      CONVERT(bit, 0)),
  (N'bench/Category',     N'ProductCategory.CategoryPath',    CONVERT(bit, 0)),
  (N'bench/Media',        N'ProductMedia.Url',                CONVERT(bit, 0)),
  (N'bench/PriceList',    N'ProductPrice.PriceList',          CONVERT(bit, 0)),
  (N'bench/Net',          N'ProductPrice.Net',                CONVERT(bit, 0)),
  (N'bench/Vat',          N'ProductPrice.VatRate',            CONVERT(bit, 0)),
  (N'bench/ValidFrom',    N'ProductPrice.ValidFrom',          CONVERT(bit, 0))
) AS source(SourceElement, TargetFieldCode, IsRequired)
  ON target.SourceConnectorId = @ConnId AND target.EntityType = @Entity
  AND target.SourceElement = source.SourceElement
WHEN MATCHED THEN
  UPDATE SET TargetFieldCode = source.TargetFieldCode, IsRequired = source.IsRequired, IsActive = 1, MappingVersion = 1
WHEN NOT MATCHED THEN
  INSERT(SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
  VALUES(@ConnId, @Entity, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1, 1);

/* ---------- 2. vhodna vrstica in izlusceni podatki ---------- */
INSERT ops.PipelineRun(RunId, Pipeline, OrganizationId, SourceCode, StartedUtc, Status, RowsRead, RowsSucceeded, RowsFailed)
VALUES(@RunId, N'BENCH_A3', @OrgId, @Src, SYSUTCDATETIME(), N'Running', 0, 0, 0);

INSERT raw.Inbox(RunId, OrganizationId, SourceCode, EntityType, PageNumber, PayloadXml, PayloadHash, Status)
VALUES(@RunId, @OrgId, @Src, @Entity, 1, N'<bench/>',
       CONVERT(char(64), HASHBYTES('SHA2_256', CONVERT(nvarchar(100), @RunId)), 2), N'Pending');
DECLARE @InboxId bigint = SCOPE_IDENTITY();

;WITH numbers AS
(
  SELECT TOP(@N) ROW_NUMBER() OVER(ORDER BY (SELECT 1)) AS i
  FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT map.ExtractedValue(InboxId, FieldMappingId, MappingVersion, RecordOrdinal, TargetFieldCode, Value, ExtractedUtc)
SELECT @InboxId, mapping.FieldMappingId, mapping.MappingVersion, numbers.i, mapping.TargetFieldCode,
  CASE mapping.TargetFieldCode
    WHEN N'Product.ItemID'               THEN CONCAT(N'BENCH-A3-', numbers.i)
    WHEN N'Product.EAN'                  THEN CONCAT(N'99', RIGHT(CONCAT(N'00000000000', numbers.i), 11))
    WHEN N'Product.UoM'                  THEN N'KOS'
    WHEN N'Product.Manufacturer'         THEN N'Bench d.o.o.'
    WHEN N'Product.ItemGroup'            THEN CONCAT(N'SKUPINA-', numbers.i % 20)
    WHEN N'Product.WebPublish'           THEN N'D'
    WHEN N'ProductText.WEB_TITLE.sl'          THEN CONCAT(N'Testni artikel ', numbers.i)
    WHEN N'ProductAttribute.BenchAttr'   THEN CONCAT(N'A', numbers.i % 50)
    WHEN N'ProductCategory.CategoryPath' THEN CONCAT(N'Bench/Kategorija ', numbers.i % 20)
    WHEN N'ProductMedia.Url'             THEN CONCAT(N'https://bench.local/', numbers.i, N'.jpg')
    WHEN N'ProductPrice.PriceList'       THEN N'BENCH'
    WHEN N'ProductPrice.Net'             THEN CONVERT(nvarchar(50), 10 + (numbers.i % 500))
    WHEN N'ProductPrice.VatRate'         THEN N'22.00'
    WHEN N'ProductPrice.ValidFrom'       THEN N'2026-01-01T00:00:00'
  END,
  SYSUTCDATETIME()
FROM numbers
CROSS JOIN map.FieldMapping mapping
WHERE mapping.SourceConnectorId = @ConnId AND mapping.EntityType = @Entity AND mapping.IsActive = 1;

/* ---------- 3. meritev ---------- */
DECLARE @t0 datetime2(7) = SYSUTCDATETIME();
EXEC map.ProcessRawInbox @RunId = @RunId, @OrganizationId = @OrgId, @SourceCode = @Src;
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSUTCDATETIME());

/* ---------- 4. kaj je nastalo ---------- */
DECLARE @Products int = (SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @OrgId AND ItemID LIKE N'BENCH-A3-%');
DECLARE @Texts int      = (SELECT COUNT(*) FROM canon.ProductText t      INNER JOIN canon.Product p ON p.ProductId = t.ProductId WHERE p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%');
DECLARE @Attributes int = (SELECT COUNT(*) FROM canon.ProductAttribute a INNER JOIN canon.Product p ON p.ProductId = a.ProductId WHERE p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%');
DECLARE @Categories int = (SELECT COUNT(*) FROM canon.ProductCategory c  INNER JOIN canon.Product p ON p.ProductId = c.ProductId WHERE p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%');
DECLARE @Media int      = (SELECT COUNT(*) FROM canon.ProductMedia m     INNER JOIN canon.Product p ON p.ProductId = m.ProductId WHERE p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%');
DECLARE @Prices int     = (SELECT COUNT(*) FROM canon.ProductPrice r     INNER JOIN canon.Product p ON p.ProductId = r.ProductId WHERE p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%');
DECLARE @Status nvarchar(60) = (SELECT Status FROM raw.Inbox WHERE InboxId = @InboxId);
DECLARE @Reason nvarchar(4000) = (SELECT FailureReason FROM raw.Inbox WHERE InboxId = @InboxId);
DECLARE @Unmapped int = (SELECT COUNT(*) FROM map.UnmappedValue u INNER JOIN map.ExtractedValue v ON v.ExtractedValueId = u.ExtractedValueId WHERE v.InboxId = @InboxId);
DECLARE @Batches int = (SELECT COUNT(*) FROM pim.ProductChangeBatch b WHERE EXISTS(SELECT 1 FROM pim.ProductFieldHistory h INNER JOIN canon.Product p ON p.ProductId = h.ProductId WHERE h.ChangeBatchId = b.ChangeBatchId AND p.OrganizationId = @OrgId AND p.ItemID LIKE N'BENCH-A3-%'));

PRINT CONCAT(N'MERITEV  zapisov=', @N, N'  cas_ms=', @ms,
             N'  zapisov_na_sekundo=', CONVERT(nvarchar(20), CONVERT(decimal(10,1), @N * 1000.0 / NULLIF(@ms, 0))));
PRINT CONCAT(N'STANJE   inbox=', @Status, N'  razlog=', COALESCE(@Reason, N'(brez)'), N'  nepreslikanih=', @Unmapped);
PRINT CONCAT(N'NASTALO  izdelki=', @Products, N'  besedila=', @Texts, N'  atributi=', @Attributes,
             N'  kategorije=', @Categories, N'  mediji=', @Media, N'  cene=', @Prices,
             N'  zgodovinskih_svezenj=', @Batches);

/* ---------- 5. pospravi za sabo ---------- */
DELETE FROM @Mine;
INSERT @Mine(ProductId)
SELECT ProductId FROM canon.Product WHERE OrganizationId = @OrgId AND ItemID LIKE N'BENCH-A3-%';

DELETE FROM @MyBatches;
INSERT @MyBatches(ChangeBatchId)
SELECT DISTINCT h.ChangeBatchId FROM pim.ProductFieldHistory h WHERE h.ProductId IN (SELECT ProductId FROM @Mine);

DELETE FROM val.ProductIssue           WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM val.ProductValidationState WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM stock.Position             WHERE MatchedProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductCommercial    WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductPrice         WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductMedia         WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductCategory      WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductAttribute     WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM canon.ProductText          WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM pim.ProductFieldHistory    WHERE ProductId IN (SELECT ProductId FROM @Mine);
DELETE FROM pim.ProductChangeBatch     WHERE ChangeBatchId IN (SELECT ChangeBatchId FROM @MyBatches)
  AND NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory h WHERE h.ChangeBatchId = pim.ProductChangeBatch.ChangeBatchId);
DELETE FROM canon.Product              WHERE ProductId IN (SELECT ProductId FROM @Mine);

DELETE FROM map.UnmappedValue
WHERE ExtractedValueId IN
(
  SELECT v.ExtractedValueId FROM map.ExtractedValue v
  INNER JOIN raw.Inbox i ON i.InboxId = v.InboxId
  WHERE i.SourceCode = @Src
);
DELETE FROM map.ExtractedValue WHERE InboxId IN (SELECT InboxId FROM raw.Inbox WHERE SourceCode = @Src);
DELETE FROM raw.Inbox WHERE SourceCode = @Src;
DELETE FROM ops.PipelineRun WHERE Pipeline = N'BENCH_A3';
DELETE FROM map.Watermark WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.FieldMapping WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.EntityMapping WHERE SourceConnectorId IN (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = @Src);
DELETE FROM map.SourceConnector WHERE SourceCode = @Src;

DECLARE @Left int =
  (SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @OrgId AND ItemID LIKE N'BENCH-A3-%')
+ (SELECT COUNT(*) FROM raw.Inbox WHERE SourceCode = @Src)
+ (SELECT COUNT(*) FROM map.SourceConnector WHERE SourceCode = @Src)
+ (SELECT COUNT(*) FROM ops.PipelineRun WHERE Pipeline = N'BENCH_A3');
PRINT CONCAT(N'POSPRAVLJENO  ostankov=', @Left);
IF @Left <> 0 THROW 60001, N'Merilo za sabo ni pospravilo vsega.', 1;
