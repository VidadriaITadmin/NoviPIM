/*
  047 — validacijski model iz slik: profili, stopnja resnosti in obseg blokade.

  Vir: pet preglednic, ki jih je 2026-08-21 dolocil narocnik (SHARED_CORE, ERP_L1_SLO,
  ERP_L1_EU/ERP_L1_THIRD, COMMERCIAL_L2, WEB_svetila_si/WEB_videlektro). Bistvo tistih
  preglednic je razlika, ki je shema doslej ni poznala:

    - obvezno polje ni isto kot polje, ki ustavi zapis;
    - ERROR ni isto kot WARNING;
    - profil, ki blokira ERP, ni isto kot profil, ki ne blokira nicesar.

  Kaj se spremeni v shemi:
    - val.ValidationProfile dobi Scope, BlocksErp in BlocksWeb; ExportProfileId sme biti NULL,
      ker SHARED_CORE ali COMMERCIAL_L2 nista izvoz;
    - val.FieldRequirement dobi Severity (ERROR | WARNING); SourceExportColumnId sme biti NULL,
      ker ti zahtevki ne izvirajo iz izvoznega stolpca;
    - canon.FieldValue vidi se ItemGroup, Department, IsActive, WebPublish in trgovinske
      podatke (teze, tarifa, drzava, Pak1, Pak2) — brez tega bi bili zahtevki slepi;
    - val.RunValidation postavi INVALID samo ob ERROR, skupni status artikla pa poslusa samo
      profile, ki kaj blokirajo. COMMERCIAL_L2 je izrecno oznacen kot profil, ki ne blokira.

  IN ENA SPREMEMBA, KI JO JE TREBA POVEDATI NAGLAS.

  Do te migracije je bila obveznost polja zapisana na dveh mestih z isto besedo, a z zelo
  razlicnim ucinkom. map.FieldMapping.IsRequired ne pomeni "obvezno polje", ampak "brez tega
  zapisa sploh ne bo": map.ProcessRawInbox tak zapis zavrne v celoti — skupaj s sifro, nazivom
  in EAN. Izmerjeno na zivem zajemu 2026-08-21: 15 od 183 artiklov (8,2 %) je izpadlo, in v
  vseh 15 primerih je manjkala samo skupina popusta.

  V dogovorjenem modelu skupina popusta ostaja obvezna — a kot ERROR v profilu ERP_L1_SLO,
  ki blokira ERP. To pomeni: artikel obstaja, je viden, je oznacen kot neveljaven za ERP in
  se ne promovira. Ne pomeni, da artikla ni.

  Zato ta migracija pusti pri zajemu obvezno samo sifro artikla (Product.ItemID) — brez nje
  zapisa ni mogoce niti nasloviti. Vse ostalo se preseli v validacijo. Ce se s tem ne
  strinjas, je popravek ena vrstica UPDATE nad map.FieldMapping; zapisano je tu, da se vidi.

  Kaj ta migracija NE naredi:
    - ne odstrani profilov ERP_L1 in WEB_B2C. Nova sedmerica stoji ob njiju, ker ju uporablja
      val.Promote (privzeti profil ERP_L1) in ju preverja migrator. Njuna upokojitev je
      locena odlocitev in locen korak.
    - ne izmislja polj. Devet zahtevkov iz preglednic nima kanonicnega polja (volumen, mere
      pakiranja, stevilo kosov v paketu, izlocitev iz rezervacije); zapisani so z IsActive = 0,
      da je model viden v celoti in se vidi, kaj manjka.

  Migrator ne pozna locila GO, zato so procedure in stavki nad pravkar dodanimi stolpci
  zaviti v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) profil: obseg in blokada ---------------------------------------- */

IF COL_LENGTH(N'val.ValidationProfile', N'Scope') IS NULL
  ALTER TABLE val.ValidationProfile ADD
    Scope nvarchar(40) NOT NULL CONSTRAINT DF_ValidationProfile_Scope DEFAULT(N'LEGACY'),
    BlocksErp bit NOT NULL CONSTRAINT DF_ValidationProfile_BlocksErp DEFAULT(0),
    BlocksWeb bit NOT NULL CONSTRAINT DF_ValidationProfile_BlocksWeb DEFAULT(0);

/*
  ExportProfileId mora smeti biti NULL. Enolicnost 1:1 z izvoznim profilom mora ostati, zato
  omejitev zamenja filtriran unikaten indeks: UNIQUE constraint bi dovolil samo en NULL.
*/
IF EXISTS(SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_ValidationProfile_ExportProfile')
BEGIN
  ALTER TABLE val.ValidationProfile DROP CONSTRAINT UQ_ValidationProfile_ExportProfile;
  ALTER TABLE val.ValidationProfile ALTER COLUMN ExportProfileId int NULL;
  CREATE UNIQUE NONCLUSTERED INDEX UQ_ValidationProfile_ExportProfile
    ON val.ValidationProfile(ExportProfileId) WHERE ExportProfileId IS NOT NULL;
END;

/* --- 2) zahtevek: stopnja resnosti -------------------------------------- */

IF COL_LENGTH(N'val.FieldRequirement', N'Severity') IS NULL
  ALTER TABLE val.FieldRequirement ADD
    Severity nvarchar(20) NOT NULL CONSTRAINT DF_FieldRequirement_Severity DEFAULT(N'ERROR');

IF NOT EXISTS(SELECT 1 FROM sys.check_constraints WHERE name = N'CK_FieldRequirement_Severity')
  EXEC(N'
ALTER TABLE val.FieldRequirement WITH CHECK ADD CONSTRAINT CK_FieldRequirement_Severity
  CHECK (Severity IN(N''ERROR'', N''WARNING''));
');

/* Zahtevki, ki ne izvirajo iz izvoznega stolpca, morajo smeti imeti NULL. */
IF EXISTS(SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_FieldRequirement_ProfileColumn')
BEGIN
  ALTER TABLE val.FieldRequirement DROP CONSTRAINT UQ_FieldRequirement_ProfileColumn;
  ALTER TABLE val.FieldRequirement ALTER COLUMN SourceExportColumnId int NULL;
  CREATE UNIQUE NONCLUSTERED INDEX UQ_FieldRequirement_ProfileColumn
    ON val.FieldRequirement(ValidationProfileId, SourceExportColumnId) WHERE SourceExportColumnId IS NOT NULL;
  /* Rocno zapisani zahtevki so enolicni po polju, ne po izvoznem stolpcu. */
  CREATE UNIQUE NONCLUSTERED INDEX UQ_FieldRequirement_ProfileField
    ON val.FieldRequirement(ValidationProfileId, FieldCode) WHERE SourceExportColumnId IS NULL;
END;

/* --- 3) canon.FieldValue vidi polja, ki jih zahtevajo profili ------------ */

EXEC(N'
CREATE OR ALTER VIEW canon.FieldValue
AS
SELECT ProductId, N''Product.ItemID'' AS FieldCode, NULLIF(ItemID, N'''') AS Value FROM canon.Product
UNION ALL SELECT ProductId, N''Product.EAN'', NULLIF(EAN, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.UoM'', NULLIF(UoM, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Supplier'', NULLIF(Supplier, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Manufacturer'', NULLIF(Manufacturer, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.AccountingGroup'', NULLIF(AccountingGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.DiscountGroup'', NULLIF(DiscountGroup, N'''') FROM canon.Product
/* Novo v 047: polja, ki jih je prinesla migracija 042, a jih validacija ni videla. */
UNION ALL SELECT ProductId, N''Product.ItemGroup'', NULLIF(ItemGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Department'', NULLIF(Department, N'''') FROM canon.Product
/*
  IsActive in WebPublish sta bit NOT NULL, zato vrednost vedno obstaja in zahtevek zanju ne
  more sprozit pomanjkljivosti. Vseeno sta tu, ker profil brez njiju ne bi bil ista stvar kot
  dogovorjeni model; ce bosta kdaj smela biti neznana, bo pravilo ze na svojem mestu.
*/
UNION ALL SELECT ProductId, N''Product.IsActive'', CONVERT(nvarchar(10), IsActive) FROM canon.Product
UNION ALL SELECT ProductId, N''Product.WebPublish'', CONVERT(nvarchar(10), WebPublish) FROM canon.Product
/* Novo v 047: trgovinski podatki, ki jih zahtevata ERP_L1_EU in COMMERCIAL_L2. */
UNION ALL SELECT ProductId, N''ProductCommercial.NetWeight'', NULLIF(CONVERT(nvarchar(50), NetWeight), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.GrossWeight'', NULLIF(CONVERT(nvarchar(50), GrossWeight), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.CustomsTariff'', NULLIF(CustomsTariff, N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.CountryOfOrigin'', NULLIF(CountryOfOrigin, N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.Pak1'', NULLIF(CONVERT(nvarchar(50), Pak1), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.Pak2'', NULLIF(CONVERT(nvarchar(50), Pak2), N'''') FROM canon.ProductCommercial
UNION ALL SELECT textValue.ProductId, CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang), NULLIF(textValue.Value, N'''') FROM canon.ProductText textValue
UNION ALL SELECT attributeValue.ProductId, CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode), NULLIF(attributeValue.Value, N'''') FROM canon.ProductAttribute attributeValue
UNION ALL SELECT ProductId, N''ProductCategory.CategoryPath'', NULLIF(CategoryPath, N'''') FROM canon.ProductCategory
UNION ALL SELECT ProductId, N''ProductMedia.Url'', NULLIF(Url, N'''') FROM canon.ProductMedia
UNION ALL SELECT ProductId, N''ProductPrice.VatRate'', CONVERT(nvarchar(50), VatRate) FROM canon.ProductPrice WHERE IsActive = 1
UNION ALL SELECT ProductId, N''ProductPrice.Gross'', CONVERT(nvarchar(50), Net * (1 + VatRate / 100)) FROM canon.ProductPrice WHERE IsActive = 1 AND Net * (1 + VatRate / 100) > 0;
');

/* --- 4) profili iz dogovorjenega modela ---------------------------------- */

EXEC(N'
MERGE val.ValidationProfile AS target
USING (VALUES
  (N''SHARED_CORE'', N''Skupno jedro - blokira ERP in splet'', N''SHARED'', 1, 1),
  (N''ERP_L1_SLO'', N''ERP L1 - obvezno za Slovenijo'', N''ERP'', 1, 0),
  (N''ERP_L1_EU'', N''ERP L1 - dodatek za EU'', N''ERP'', 1, 0),
  (N''ERP_L1_THIRD'', N''ERP L1 - dodatek za tretje drzave'', N''ERP'', 1, 0),
  (N''COMMERCIAL_L2'', N''Trgovinski podatki L2 - ne blokira'', N''COMMERCIAL'', 0, 0),
  (N''WEB_svetila_si'', N''Splet svetila.si'', N''WEB'', 0, 1),
  (N''WEB_videlektro'', N''Splet videlektro'', N''WEB'', 0, 1)
) AS source(ProfileCode, Name, Scope, BlocksErp, BlocksWeb)
  ON target.ProfileCode = source.ProfileCode
WHEN MATCHED THEN
  UPDATE SET Name = source.Name, Scope = source.Scope, BlocksErp = source.BlocksErp, BlocksWeb = source.BlocksWeb, IsActive = 1
WHEN NOT MATCHED THEN
  INSERT (ProfileCode, Name, ExportProfileId, Scope, BlocksErp, BlocksWeb, IsActive)
  VALUES (source.ProfileCode, source.Name, NULL, source.Scope, source.BlocksErp, source.BlocksWeb, 1);
');

/* --- 5) zahtevki -------------------------------------------------------- */

EXEC(N'
MERGE val.FieldRequirement AS target
USING
(
  SELECT profile.ValidationProfileId, source.FieldCode, source.Severity, source.IsActive
  FROM (VALUES
  (N''SHARED_CORE'', N''Product.ItemID'', N''ERROR'', 1),
  (N''SHARED_CORE'', N''Product.EAN'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''ProductText.TITLE_ERP.sl'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.AccountingGroup'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.DiscountGroup'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.UoM'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.Supplier'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.Manufacturer'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.IsActive'', N''ERROR'', 1),
  (N''ERP_L1_SLO'', N''Product.PiecesInPackage'', N''WARNING'', 0),
  (N''ERP_L1_SLO'', N''Product.QtyReservationExcluded'', N''ERROR'', 0),
  (N''ERP_L1_EU'', N''ProductCommercial.NetWeight'', N''ERROR'', 1),
  (N''ERP_L1_EU'', N''ProductCommercial.GrossWeight'', N''ERROR'', 1),
  (N''ERP_L1_EU'', N''ProductCommercial.CustomsTariff'', N''ERROR'', 1),
  (N''ERP_L1_EU'', N''ProductCommercial.CountryOfOrigin'', N''ERROR'', 1),
  (N''ERP_L1_THIRD'', N''ProductCommercial.NetWeight'', N''ERROR'', 1),
  (N''ERP_L1_THIRD'', N''ProductCommercial.GrossWeight'', N''ERROR'', 1),
  (N''ERP_L1_THIRD'', N''ProductCommercial.CustomsTariff'', N''ERROR'', 1),
  (N''ERP_L1_THIRD'', N''ProductCommercial.CountryOfOrigin'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.GrossWeight'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.NetWeight'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.Volume'', N''ERROR'', 0),
  (N''COMMERCIAL_L2'', N''ProductCommercial.PackageLength'', N''ERROR'', 0),
  (N''COMMERCIAL_L2'', N''ProductCommercial.PackageWidth'', N''ERROR'', 0),
  (N''COMMERCIAL_L2'', N''ProductCommercial.PackageHeight'', N''ERROR'', 0),
  (N''COMMERCIAL_L2'', N''ProductCommercial.CustomsTariff'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.CountryOfOrigin'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.Pak1'', N''ERROR'', 1),
  (N''COMMERCIAL_L2'', N''ProductCommercial.Pak2'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''Product.Manufacturer'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''Product.Department'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''Product.ItemGroup'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''ProductText.WEB_TITLE.sl'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''ProductText.WEB_TITLE.en'', N''WARNING'', 1),
  (N''WEB_svetila_si'', N''ProductCategory.CategoryPath'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''ProductPrice.Gross'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''ProductPrice.VatRate'', N''ERROR'', 1),
  (N''WEB_svetila_si'', N''ProductMedia.Url'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''Product.Manufacturer'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''Product.Department'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''Product.ItemGroup'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''ProductText.WEB_TITLE.sl'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''ProductText.WEB_TITLE.en'', N''WARNING'', 1),
  (N''WEB_videlektro'', N''ProductCategory.CategoryPath'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''ProductPrice.Gross'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''ProductPrice.VatRate'', N''ERROR'', 1),
  (N''WEB_videlektro'', N''ProductMedia.Url'', N''ERROR'', 1)

  ) AS source(ProfileCode, FieldCode, Severity, IsActive)
  INNER JOIN val.ValidationProfile profile ON profile.ProfileCode = source.ProfileCode
) AS source
  ON target.ValidationProfileId = source.ValidationProfileId
  AND target.FieldCode = source.FieldCode
  AND target.SourceExportColumnId IS NULL
WHEN MATCHED THEN
  UPDATE SET Severity = source.Severity, IsRequired = 1, IsActive = source.IsActive
WHEN NOT MATCHED THEN
  INSERT (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive, Severity)
  VALUES (source.ValidationProfileId, NULL, source.FieldCode, 1, source.IsActive, source.Severity);
');

/* --- 6) validacija poslusa stopnjo resnosti in obseg blokade ------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    WHERE issue.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      );

    /*
      Novost 047: stopnja resnosti odloca o statusu, ne o tem, ali se pomanjkljivost zabelezi.
      WARNING se se vedno zapise kot val.ProductIssue — urednik ga vidi — a profila ne
      postavi na INVALID. Popolnost se steje po vseh aktivnih zahtevkih, ker meri polnost
      podatka in ne blokade.
    */
    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    /*
      Skupni status artikla poslusa samo profile, ki kaj blokirajo. COMMERCIAL_L2 je izrecno
      oznacen kot profil, ki ne blokira ne ERP ne spleta: njegove pomanjkljivosti so vidne v
      val.ProductIssue, artikla pa ne smejo razglasiti za neveljavnega. Prej je vsak aktiven
      zapis pomanjkljivosti — katerekoli resnosti in kateregakoli profila — postavil INVALID.
    */
    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;
');


/* --- 7) zajem zavrne zapis samo brez sifre artikla ----------------------- */

/*
  Obveznost polj je zdaj v validaciji. Pri zajemu ostane obvezna samo sifra: brez nje zapisa
  ni mogoce niti nasloviti, vse ostalo pa mora pristati v katalogu in tam biti oznaceno.
*/
UPDATE mapping
SET IsRequired = 0
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.ConnectorType = N'SAOP'
  AND mapping.IsRequired = 1
  AND mapping.TargetFieldCode <> N'Product.ItemID';

/* --- 8) varovalke ------------------------------------------------------- */

EXEC(N'
IF (SELECT COUNT(*) FROM val.ValidationProfile WHERE Scope <> N''LEGACY'' AND IsActive = 1) <> 7
  THROW 52360, ''Ni nastalo sedem novih validacijskih profilov.'', 1;
IF EXISTS(SELECT 1 FROM val.FieldRequirement WHERE Severity NOT IN(N''ERROR'', N''WARNING''))
  THROW 52361, ''Zahtevek ima neznano stopnjo resnosti.'', 1;
IF EXISTS
(
  SELECT 1 FROM map.FieldMapping mapping
  INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.ConnectorType = N''SAOP'' AND mapping.IsRequired = 1 AND mapping.TargetFieldCode <> N''Product.ItemID''
)
  THROW 52362, ''Pri zajemu je obvezno se kaksno polje poleg sifre artikla.'', 1;
');
