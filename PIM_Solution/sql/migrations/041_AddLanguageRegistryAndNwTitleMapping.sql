/*
  Dva namena, oba idempotentna:

  1) Register jezikov. canon.ProductText(ProductId, Lang, TextType) ze podpira
     N jezikov x N tipov besedila, Lang pa je bil prost nvarchar(20) brez
     seznama dovoljenih vrednosti. Brez registra uporabnik ne more dodati
     jezika brez posega v kodo, hkrati pa se v podatke prikradejo variante
     istega jezika (sl / SL / sl-SI). Register je referencni sifrant; FK na
     canon.ProductText namenoma NE dodajamo, ker bi obstojeci uvozi lahko
     odpovedali sredi paketa - najprej register, uveljavljanje pozneje.

  2) NW_XML product_name je bil preslikan v mrtvo tarco Unsupported.F5Probe.
     Datoteka dobavitelja je products_en_US.xml in <product_name> je ANGLESKI
     naziv modela (npr. "ARES"), zato pravilna tarca ni WEB_TITLE.sl ampak
     WEB_TITLE.en. Slovenski spletni naziv ostane locena, rocno ali strojno
     pripravljena vrednost - iz te datoteke ga ni mogoce dobiti.

     val.RunValidation ne zahteva WEB_TITLE.en, zato ta sprememba nobenega
     izdelka ne premakne iz VALID v INVALID.
*/

SET XACT_ABORT ON;

/* --- 1) Register jezikov ------------------------------------------------ */

IF OBJECT_ID(N'dbo.Language', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.Language
  (
    LanguageId int IDENTITY(1,1) NOT NULL,
    Code nvarchar(20) NOT NULL,
    Name nvarchar(100) NOT NULL,
    NativeName nvarchar(100) NOT NULL,
    IsDefault bit NOT NULL CONSTRAINT DF_Language_IsDefault DEFAULT(0),
    IsActive bit NOT NULL CONSTRAINT DF_Language_IsActive DEFAULT(1),
    SortOrder int NOT NULL CONSTRAINT DF_Language_SortOrder DEFAULT(100),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Language_CreatedUtc DEFAULT(SYSUTCDATETIME()),
    UpdatedUtc datetime2(3) NULL,
    UpdatedBy nvarchar(100) NULL,
    CONSTRAINT PK_Language PRIMARY KEY CLUSTERED (LanguageId),
    CONSTRAINT UQ_Language_Code UNIQUE (Code)
  );
END;

/* Natanko en privzeti jezik. Filtriran unique index, ne CHECK - CHECK
   ne more gledati cez vrstice. */
IF NOT EXISTS
(
  SELECT 1 FROM sys.indexes
  WHERE object_id = OBJECT_ID(N'dbo.Language') AND name = N'UX_Language_SingleDefault'
)
  CREATE UNIQUE INDEX UX_Language_SingleDefault
    ON dbo.Language(IsDefault) WHERE IsDefault = 1;

MERGE dbo.Language AS target
USING (VALUES
  (N'sl', N'Slovenian', N'slovenscina', 1, 1, 10),
  (N'en', N'English',   N'English',     0, 1, 20),
  (N'de', N'German',    N'Deutsch',     0, 1, 30),
  (N'hr', N'Croatian',  N'hrvatski',    0, 1, 40)
) source(Code, Name, NativeName, IsDefault, IsActive, SortOrder)
ON target.Code = source.Code
WHEN MATCHED AND
(
  target.Name <> source.Name
  OR target.NativeName <> source.NativeName
  OR target.SortOrder <> source.SortOrder
)
  THEN UPDATE SET
    Name = source.Name,
    NativeName = source.NativeName,
    SortOrder = source.SortOrder,
    UpdatedUtc = SYSUTCDATETIME(),
    UpdatedBy = N'MIGRATION_041'
WHEN NOT MATCHED THEN
  INSERT(Code, Name, NativeName, IsDefault, IsActive, SortOrder)
  VALUES(source.Code, source.Name, source.NativeName, source.IsDefault, source.IsActive, source.SortOrder);

/* IsDefault in IsActive namenoma nista v UPDATE veji: ce jih skrbnik pozneje
   spremeni v intranetu, jih ponovni zagon migracije ne sme povoziti. */

/* --- 2) NW_XML product_name -> ProductText.WEB_TITLE.en ----------------- */

UPDATE fieldMapping
SET TargetFieldCode = N'ProductText.WEB_TITLE.en'
FROM map.FieldMapping fieldMapping
INNER JOIN map.SourceConnector sourceConnector
  ON sourceConnector.SourceConnectorId = fieldMapping.SourceConnectorId
WHERE sourceConnector.SourceCode = N'NW_XML'
  AND fieldMapping.EntityType = N'Attribute'
  AND fieldMapping.SourceElement = N'product_name/text()[1]'
  AND fieldMapping.TargetFieldCode = N'Unsupported.F5Probe';
