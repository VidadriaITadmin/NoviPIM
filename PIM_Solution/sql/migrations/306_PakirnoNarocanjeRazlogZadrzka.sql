/*
  306 — Pakirno naročanje: zadržek pravila 302 pove pravi razlog.

  Preverjalec naloge #5 (2026-09-29): kartica izdelka kaže Pakiranje 2 iz zajema/uvoza
  (canon.ProductCommercial), pravilo 302 in katalog.csv pa objavljeno vrednost (pim.ProductCommercial,
  polni jo val.Promote po uspešni validaciji). Na razvojni bazi je imelo 163 od 166 zadržanih artiklov
  Pakiranje 2 že vpisano (npr. 50), razlog zadržka pa je velel »vpiši Pakiranje 2« — zavajajoče.

  Pravilo ostaja enako (katalog.csv mora imeti Pakirno naročanje = 1 samo skupaj z objavljeno
  Pakirno količino > 1, sicer bi Magento naročal po paketih z velikostjo 1). Spremeni se samo razlog:
    A) Pakiranje 2 ni vpisano niti v zajemu → »vpiši Pakiranje 2 (večje od 1) ali odstrani oznako«;
    B) Pakiranje 2 je vpisano, artikel pa še ni objavljen v PIM → »čaka objavo v PIM«;
    C) Pakiranje 2 je vpisano, objavljena vrednost je še stara → »na splet gre še objavljena vrednost Y«.
  Pri B in C se zadržek sprosti sam ob prvem izvozu katalog.csv po objavi (izvoz pred sestavo pokliče
  val.SyncPackageOrderHolds). Razlog obstoječih aktivnih zadržkov pravila se posodobi, ko se stanje
  spremeni (npr. iz A v C po zajemu iz SAOP). Ročnih zadržkov (drug CreatedBy) pravilo ne spreminja.

  Spremenjeno: val.SyncPackageOrderHolds (CREATE OR ALTER, isti parametri in izhodi kot v 302).
  SAOP: nič. Ročni korak: ne. Ponovljivo: da.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53060, N'306: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'val.SyncPackageOrderHolds', N'P') IS NULL
  THROW 53061, N'306: najprej mora biti uveljavljena 302 (val.SyncPackageOrderHolds).', 1;

EXEC(N'CREATE OR ALTER PROCEDURE val.SyncPackageOrderHolds
  @OrganizationId int = NULL,
  @ProductId bigint = NULL,
  @Held int = NULL OUTPUT,
  @Released int = NULL OUTPUT
AS
BEGIN
  /* 302/306: artikel s »Pakirnim naročanjem« brez OBJAVLJENEGA Pakiranja 2 (> 1) ne sme na splet, ker
     katalog.csv nosi objavljeno »Pakirno količino« (pim.ProductCommercial). Pravilo vodi samo svoje
     zadržke (CreatedBy = pravilo 302); ročnega zadržka ne prepiše in ne sprosti. Razlog (306) pove, ali
     Pakiranje 2 manjka ali samo čaka objavo v PIM. */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Rule nvarchar(200) = N''pravilo 302'';

  CREATE TABLE #Missing (ProductId bigint NOT NULL PRIMARY KEY, Reason nvarchar(500) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Missing (ProductId, Reason)
  SELECT flag.ProductId,
         CASE
           WHEN ISNULL(captured.Pak2, 0) <= 1
             THEN N''Pakirno naročanje brez količine paketa: vpiši Pakiranje 2 (večje od 1) ali odstrani oznako Pakirno naročanje.''
           WHEN promoted.PimProductId IS NULL
             THEN CONCAT(N''Pakirno naročanje: Pakiranje 2 je vpisano ('', CONVERT(nvarchar(40), CONVERT(float, captured.Pak2)),
                         N''), artikel pa še ni objavljen v PIM (objava teče po uspešni validaciji). Zadržek se sprosti sam ob prvem izvozu katalog.csv po objavi.'')
           ELSE CONCAT(N''Pakirno naročanje: Pakiranje 2 je vpisano ('', CONVERT(nvarchar(40), CONVERT(float, captured.Pak2)),
                       N''), na splet pa gre še objavljena vrednost ('',
                       ISNULL(CONVERT(nvarchar(40), CONVERT(float, commercial.Pak2)), N''prazno''),
                       N''). Zadržek se sprosti sam ob prvem izvozu katalog.csv po naslednji objavi v PIM (po uspešni validaciji).'')
         END
  FROM pim.ProductFlag AS flag
  INNER JOIN canon.Product AS product ON product.ProductId = flag.ProductId
  LEFT JOIN canon.ProductCommercial AS captured ON captured.ProductId = product.ProductId
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = promoted.PimProductId
  WHERE flag.FlagCode = N''PAKIRNO_NAROCANJE'' AND flag.IsSet = 1
    AND ISNULL(commercial.Pak2, 0) <= 1
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND (@ProductId IS NULL OR flag.ProductId = @ProductId);

  BEGIN TRANSACTION;

  INSERT val.ProductHold (ProductId, ChannelCode, Reason, CreatedBy)
  SELECT missing.ProductId, N''WEB'', missing.Reason, @Rule
  FROM #Missing AS missing
  WHERE NOT EXISTS (SELECT 1 FROM val.ProductHold AS hold
                    WHERE hold.ProductId = missing.ProductId AND hold.IsActive = 1 AND hold.ChannelCode IN (N''WEB'', N''ALL''));
  SET @Held = @@ROWCOUNT;

  /* 306: razlog aktivnega zadržka pravila sledi stanju (manjka / čaka objavo). */
  UPDATE hold SET Reason = missing.Reason
  FROM val.ProductHold AS hold
  INNER JOIN #Missing AS missing ON missing.ProductId = hold.ProductId
  WHERE hold.IsActive = 1 AND hold.CreatedBy = @Rule AND hold.Reason <> missing.Reason;

  UPDATE hold SET IsActive = 0, ReleasedUtc = SYSUTCDATETIME(), ReleasedBy = @Rule
  FROM val.ProductHold AS hold
  INNER JOIN canon.Product AS product ON product.ProductId = hold.ProductId
  WHERE hold.IsActive = 1 AND hold.CreatedBy = @Rule
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND (@ProductId IS NULL OR hold.ProductId = @ProductId)
    AND NOT EXISTS (SELECT 1 FROM #Missing AS missing WHERE missing.ProductId = hold.ProductId);
  SET @Released = @@ROWCOUNT;

  COMMIT TRANSACTION;
END;');

IF OBJECT_DEFINITION(OBJECT_ID(N'val.SyncPackageOrderHolds')) NOT LIKE N'%306: razlog aktivnega zadržka%'
  THROW 53062, N'306: val.SyncPackageOrderHolds ni posodobljen.', 1;

/* Obstoječi zadržki pravila dobijo pravi razlog. */
EXEC val.SyncPackageOrderHolds;
