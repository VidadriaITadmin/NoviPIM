/*
  122 — sifrant atributov s stalnimi kodami in preslikava izvornih atributov nanje.

  --- Zakaj stalne kode ---------------------------------------------------------------------

  Atribut je bil doslej prosto besedilo: slovensko ime, zapisano v canon.ProductAttribute.
  Ker registra ni bilo, si je vsak vir izmislil svoja imena za iste lastnosti. Izmerjeno
  2026-08-27: 158 ciljev preslikav, od tega 26 skupnih obema dobaviteljema, 82 samo
  Nowodvorski, 50 samo Braytron. Braytronova "Neto teza (2)" je natanko trenutek, ko je nekdo
  videl, da ime ze obstaja, in dodal drugo.

  Slovensko ime kot koda ima se drugo posledico. Ker canon.ProductAttribute nima stolpca za
  jezik, je jezik pristal v imenu: "Dopolnilna barva I SLO" in "Dopolnilna barva I ANG" sta dva
  atributa za eno lastnost. Takih kod je 33 za 17 lastnosti in nosijo 97.244 vrstic. Enako se
  je zgodilo z enoto: "Enota napetosti", "Enota svetlobnega toka" - 34 kod, 58.002 vrstic.

  Skupaj 155.246 od 312.257 vrstic - polovica vseh podatkov o atributih - obstaja samo zato,
  ker sta jezik in enota zapisana v ime.

  Odlocitev uporabnika 2026-08-28: atribut dobi stalno kodo, ime pa je prevod med drugimi -
  isti mehanizem kot pri kategorijah (110, 113).

  --- Kaj ta migracija naredi in cesa NE ----------------------------------------------------

  Naredi sifrant, prevode in preslikavo ter jih napolni iz danasnjega stanja.

  NE dotakne se canon.ProductAttribute. Nobena vrednost se ne premakne, noben izvoz in nobena
  validacija ne spremenita vedenja. Zlaganje jezika in enote z imena na vrednost je locen korak
  z lastnim dokazom pred in po, ker je edini, ki se dotakne izvozov.

  --- Enote: kaj je namenoma prepusceno cloveku ---------------------------------------------

  "Enota napetosti" pripada atributu "Napetost", "Enota dolzine paketa II" pa "Dolzina paketa
  II". Ta pretvorba v slovenscini ni mehanska (rodilnik -> imenovalnik) in ugibanje bi dalo
  napacne pare, ki bi izgledali pravilno. Zato so take vrstice oznacene z IsUnitCandidate = 1
  in cakajo na cloveka; sifrant pove, da gre za enoto, ne pove pa, cigavo.
*/

SET XACT_ABORT ON;

/* --- 1) Stalna koda iz imena --------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER FUNCTION canon.AttributeCodeFromName(@Name nvarchar(400))
RETURNS nvarchar(200)
AS
BEGIN
  /*
    Koda je deterministicna preslikava imena: sumniki v ASCII, locila in presledki v podcrtaj,
    velike crke. Deterministicna zato, da isto ime vedno da isto kodo - tudi cez pol leta, ko
    bo nekdo dodal vir z istim atributom.
  */
  DECLARE @Code nvarchar(400) = LTRIM(RTRIM(@Name));
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, NCHAR(269), N''c''), NCHAR(353), N''s''), NCHAR(382), N''z'');
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, NCHAR(268), N''C''), NCHAR(352), N''S''), NCHAR(381), N''Z'');
  SET @Code = REPLACE(REPLACE(@Code, NCHAR(263), N''c''), NCHAR(262), N''C'');
  SET @Code = REPLACE(REPLACE(@Code, NCHAR(273), N''d''), NCHAR(272), N''D'');
  SET @Code = REPLACE(REPLACE(REPLACE(REPLACE(@Code, N''('', N''''), N'')'', N''''), N''/'', N'' ''), N''.'', N'' '');
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, N''-'', N'' ''), N'','', N'' ''), N''%'', N'' '');
  WHILE CHARINDEX(N''  '', @Code) > 0 SET @Code = REPLACE(@Code, N''  '', N'' '');
  SET @Code = UPPER(REPLACE(LTRIM(RTRIM(@Code)), N'' '', N''_''));
  RETURN LEFT(@Code, 200);
END;
');

/* --- 2) Sifrant atributov ------------------------------------------------------------------ */

EXEC(N'
IF OBJECT_ID(N''canon.AttributeDefinition'') IS NULL
BEGIN
  CREATE TABLE canon.AttributeDefinition
  (
    AttributeDefinitionId int IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_AttributeDefinition PRIMARY KEY,
    AttributeCode    nvarchar(200) NOT NULL,
    AttributeGroup   nvarchar(100) NULL,
    DataType         nvarchar(20)  NOT NULL CONSTRAINT DF_AttributeDefinition_DataType DEFAULT(N''TEXT''),
    Unit             nvarchar(50)  NULL,
    IsTranslatable   bit NOT NULL CONSTRAINT DF_AttributeDefinition_IsTranslatable DEFAULT(0),
    /* Vrstica je videti kot enota nekega drugega atributa; cigava, pove clovek. */
    IsUnitCandidate  bit NOT NULL CONSTRAINT DF_AttributeDefinition_IsUnitCandidate DEFAULT(0),
    IsActive         bit NOT NULL CONSTRAINT DF_AttributeDefinition_IsActive DEFAULT(1),
    SortOrder        int NOT NULL CONSTRAINT DF_AttributeDefinition_SortOrder DEFAULT(100),
    Note             nvarchar(600) NULL,
    UpdatedUtc       datetime2(7) NOT NULL CONSTRAINT DF_AttributeDefinition_UpdatedUtc DEFAULT(SYSUTCDATETIME()),
    UpdatedBy        nvarchar(200) NULL,
    CONSTRAINT UQ_AttributeDefinition UNIQUE (AttributeCode),
    CONSTRAINT CK_AttributeDefinition_DataType
      CHECK (DataType IN (N''TEXT'', N''NUMBER'', N''BOOL'', N''ENUM''))
  );
END;
');

EXEC(N'
IF OBJECT_ID(N''canon.AttributeTranslation'') IS NULL
BEGIN
  CREATE TABLE canon.AttributeTranslation
  (
    AttributeTranslationId int IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_AttributeTranslation PRIMARY KEY,
    AttributeCode nvarchar(200) NOT NULL,
    LanguageCode  nvarchar(10)  NOT NULL,
    Name          nvarchar(400) NOT NULL,
    CONSTRAINT UQ_AttributeTranslation UNIQUE (AttributeCode, LanguageCode)
  );
END;
');

EXEC(N'
IF OBJECT_ID(N''canon.AttributeTranslationHistory'') IS NULL
BEGIN
  CREATE TABLE canon.AttributeTranslationHistory
  (
    AttributeTranslationHistoryId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_AttributeTranslationHistory PRIMARY KEY,
    AttributeCode nvarchar(200) NOT NULL,
    LanguageCode  nvarchar(10)  NOT NULL,
    OldName       nvarchar(400) NULL,
    NewName       nvarchar(400) NOT NULL,
    ChangedBy     nvarchar(200) NOT NULL,
    ChangedUtc    datetime2(7)  NOT NULL
      CONSTRAINT DF_AttributeTranslationHistory_ChangedUtc DEFAULT(SYSUTCDATETIME())
  );
END;
');

/* --- 3) Izvorni atribut -> nasa koda -------------------------------------------------------- */

EXEC(N'
IF OBJECT_ID(N''map.AttributeMap'') IS NULL
BEGIN
  CREATE TABLE map.AttributeMap
  (
    AttributeMapId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_AttributeMap PRIMARY KEY,
    SourceCode          nvarchar(100) NOT NULL,
    SourceAttributeName nvarchar(400) NOT NULL,
    AttributeCode       nvarchar(200) NOT NULL,
    /* Vir nosi to lastnost v tem jeziku; prazno pomeni jezikovno nevtralno. */
    LanguageCode        nvarchar(10)  NULL,
    /* Vir nosi enoto te lastnosti, ne njene vrednosti. */
    IsUnit              bit NOT NULL CONSTRAINT DF_AttributeMap_IsUnit DEFAULT(0),
    IsActive            bit NOT NULL CONSTRAINT DF_AttributeMap_IsActive DEFAULT(1),
    UpdatedUtc          datetime2(7) NOT NULL CONSTRAINT DF_AttributeMap_UpdatedUtc DEFAULT(SYSUTCDATETIME()),
    UpdatedBy           nvarchar(200) NULL,
    Note                nvarchar(600) NULL,
    CONSTRAINT UQ_AttributeMap UNIQUE (SourceCode, SourceAttributeName)
  );
  CREATE INDEX IX_AttributeMap_Koda ON map.AttributeMap(AttributeCode);
END;
');

EXEC(N'
IF OBJECT_ID(N''map.AttributeMapHistory'') IS NULL
BEGIN
  CREATE TABLE map.AttributeMapHistory
  (
    AttributeMapHistoryId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_AttributeMapHistory PRIMARY KEY,
    SourceCode          nvarchar(100) NOT NULL,
    SourceAttributeName nvarchar(400) NOT NULL,
    OldAttributeCode    nvarchar(200) NULL,
    NewAttributeCode    nvarchar(200) NULL,
    OldIsActive         bit NULL,
    NewIsActive         bit NULL,
    ChangedBy           nvarchar(200) NOT NULL,
    ChangedUtc          datetime2(7) NOT NULL
      CONSTRAINT DF_AttributeMapHistory_ChangedUtc DEFAULT(SYSUTCDATETIME()),
    Note                nvarchar(600) NULL
  );
END;
');

/* --- 4) Polnjenje sifranta iz danasnjega stanja --------------------------------------------- */

EXEC(N'
/*
  Vir imen sta dva in oba stejeta: cilji aktivnih preslikav (kaj sistem zna zapisati) in kode,
  ki so v canon.ProductAttribute ze zapisane (kaj je sistem zapisal). Drugi seznam je vecji od
  prvega, ker vsebuje tudi to, kar so zapisale preslikave, ki jih danes ni vec.
*/
DECLARE @Imena TABLE (Ime nvarchar(400) NOT NULL PRIMARY KEY);

INSERT @Imena (Ime)
SELECT DISTINCT REPLACE(fm.TargetFieldCode, N''ProductAttribute.'', N'''')
FROM map.FieldMapping fm
WHERE fm.IsActive = 1 AND fm.EntityType = N''Attribute''
  AND fm.TargetFieldCode LIKE N''ProductAttribute.%''
UNION
SELECT DISTINCT AttributeCode FROM canon.ProductAttribute;

/*
  Jezik z imena: koncnici " SLO" in " ANG" nista del lastnosti, ampak jezik njene vrednosti.
  Iz para nastane ena kanonicna lastnost, oznacena kot prevedljiva.
*/
DECLARE @Pojmi TABLE
(
  Ime nvarchar(400) NOT NULL PRIMARY KEY,
  Pojem nvarchar(400) NOT NULL,
  Jezik nvarchar(10) NULL,
  JeEnota bit NOT NULL
);

INSERT @Pojmi (Ime, Pojem, Jezik, JeEnota)
SELECT
  i.Ime,
  CASE WHEN i.Ime LIKE N''% SLO'' OR i.Ime LIKE N''% ANG''
       THEN LTRIM(RTRIM(LEFT(i.Ime, LEN(i.Ime) - 4))) ELSE i.Ime END,
  CASE WHEN i.Ime LIKE N''% SLO'' THEN N''sl''
       WHEN i.Ime LIKE N''% ANG'' THEN N''en'' ELSE NULL END,
  CASE WHEN i.Ime LIKE N''Enota %'' THEN 1 ELSE 0 END
FROM @Imena i;

MERGE canon.AttributeDefinition AS target
USING
(
  SELECT
    canon.AttributeCodeFromName(p.Pojem) AS AttributeCode,
    MAX(CASE WHEN p.Jezik IS NULL THEN 0 ELSE 1 END) AS IsTranslatable,
    MAX(CAST(p.JeEnota AS int)) AS IsUnitCandidate
  FROM @Pojmi p
  WHERE NULLIF(LTRIM(RTRIM(p.Pojem)), N'''') IS NOT NULL
  GROUP BY canon.AttributeCodeFromName(p.Pojem)
) AS source
  ON target.AttributeCode = source.AttributeCode
WHEN NOT MATCHED THEN INSERT
  (AttributeCode, IsTranslatable, IsUnitCandidate, UpdatedBy, Note)
  VALUES (source.AttributeCode, source.IsTranslatable, source.IsUnitCandidate, N''migracija 122'',
          N''Izpeljano iz danasnjih imen atributov.'');

/* Slovensko ime je prvi prevod. Ostali jeziki so prazni in to je vidno stanje, ne izguba. */
MERGE canon.AttributeTranslation AS target
USING
(
  SELECT canon.AttributeCodeFromName(p.Pojem) AS AttributeCode, N''sl'' AS LanguageCode,
         MIN(p.Pojem) AS Name
  FROM @Pojmi p
  WHERE NULLIF(LTRIM(RTRIM(p.Pojem)), N'''') IS NOT NULL
  GROUP BY canon.AttributeCodeFromName(p.Pojem)
) AS source
  ON target.AttributeCode = source.AttributeCode AND target.LanguageCode = source.LanguageCode
WHEN NOT MATCHED THEN INSERT (AttributeCode, LanguageCode, Name)
  VALUES (source.AttributeCode, source.LanguageCode, source.Name);
');

/* --- 5) Polnjenje preslikave iz obstojecih pravil ------------------------------------------- */

EXEC(N'
/*
  Izvorni atribut se poveze s pravilom, ki ga danes bere. Ujemanje je po CELI besedi: "type" se
  ne sme ujeti na "type_of_cable", sicer bi neposlikan atribut izgledal preslikan - to je
  natanko napaka, ki jo register lovi.
*/
MERGE map.AttributeMap AS target
USING
(
  SELECT
    registrirano.SourceCode,
    registrirano.SourceAttributeName,
    canon.AttributeCodeFromName(
      CASE WHEN pojem.Ime LIKE N''% SLO'' OR pojem.Ime LIKE N''% ANG''
           THEN LTRIM(RTRIM(LEFT(pojem.Ime, LEN(pojem.Ime) - 4))) ELSE pojem.Ime END) AS AttributeCode,
    CASE WHEN pojem.Ime LIKE N''% SLO'' THEN N''sl''
         WHEN pojem.Ime LIKE N''% ANG'' THEN N''en'' ELSE NULL END AS LanguageCode,
    CASE WHEN pojem.Ime LIKE N''Enota %'' THEN 1 ELSE 0 END AS IsUnit
  FROM map.SourceAttribute registrirano
  CROSS APPLY
  (
    SELECT TOP (1) REPLACE(fm.TargetFieldCode, N''ProductAttribute.'', N'''') AS Ime
    FROM map.FieldMapping fm
    INNER JOIN map.SourceConnector konektor
      ON konektor.SourceConnectorId = fm.SourceConnectorId AND konektor.SourceCode = registrirano.SourceCode
    WHERE fm.IsActive = 1 AND fm.EntityType = N''Attribute''
      AND fm.TargetFieldCode LIKE N''ProductAttribute.%''
      AND PATINDEX(N''%[^a-zA-Z0-9_]'' + registrirano.SourceAttributeName + N''[^a-zA-Z0-9_]%'',
                   N'' '' + fm.SourceElement + N'' '') > 0
    ORDER BY fm.FieldMappingId
  ) pojem
) AS source
  ON target.SourceCode = source.SourceCode AND target.SourceAttributeName = source.SourceAttributeName
WHEN NOT MATCHED THEN INSERT
  (SourceCode, SourceAttributeName, AttributeCode, LanguageCode, IsUnit, IsActive, UpdatedBy, Note)
  VALUES (source.SourceCode, source.SourceAttributeName, source.AttributeCode, source.LanguageCode,
          source.IsUnit, 1, N''migracija 122'', N''Izpeljano iz obstojece preslikave polja.'');
');
