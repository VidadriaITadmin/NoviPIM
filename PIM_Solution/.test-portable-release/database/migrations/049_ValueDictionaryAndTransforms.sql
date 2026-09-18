/*
  049 — slovar vrednosti in pretvorbe nad preslikanimi vrednostmi.

  Zakaj: map.FieldMapping zna samo "vzemi to pot, daj v to polje". To zadošča, dokler
  imamo enega dobavitelja. Ko jih je vec, ista lastnost pride v razlicni obliki:

    Nowodvorski   <ceiling_cup_height_value>3</> + <ceiling_cup_height_unit>cm</>
    Braytron      <value>30 mm</value>                     (vrednost in enota skupaj)
    Nowodvorski   <lamp_includes_source_of_light_value>No</>
    Braytron      <value>Not-Dimmable</value>              (Da/Ne kot besedilo)
    Braytron      <value> CLASS II</value> in <value>Class I</value>   (neenoten zapis)
    oba           vrednosti so angleske, predloga Magenta ima stolpce ANG in SLO

  Preslikava sama tega ne more resiti in za vsak tak primer pisati kodo pomeni, da je
  vsak nov dobavitelj nova namestitev. Zato tu nastaneta dve stvari:

    map.FieldTransform — kaj se z vrednostjo zgodi po tem, ko je izlusena iz XML-a
    map.ValueLookup    — slovar vrednosti (angleska vrednost -> slovenska, nemska, hrvaska)

  Kanonicna koda ostane sticisce: NW attribute_light_source in Braytron slug=socket
  oba piseta v ProductAttribute.Grlo ANG. Nov dobavitelj je zato vrstica v registru,
  ne veja v programu.

  Vrsta pretvorbe (map.FieldTransform.TransformCode):
    TRIM         odvzame presledke na robu
    NUMBER       vzame vodilni stevilcni del in vejico pretvori v piko  ("10,8 kg" -> "10.8")
    UNIT         vzame preostanek za stevilko                            ("10,8 kg" -> "kg")
    PREFIX       pripne predpono iz Argument                             ("203" -> "NW.203")
    STRIPPREFIX  odreze predpono iz Argument                             (" CLASS II" -> "II")
    BOOL         Argument je s podpicjem locen seznam resnicnih vrednosti ("Yes;Dimmable") -> 1 ali 0
    UPPER/LOWER  velikost crk
    LOOKUP       prevede vrednost prek map.ValueLookup; Argument je jezik ("SL")

  Korakov je lahko vec zapored (StepOrder): najprej TRIM, nato LOOKUP.

  Sledljivost: izvorna vrednost se ne izgubi. Pred prvo pretvorbo se prepise v
  map.ExtractedValue.RawValue in tam ostane; Value nosi pretvorjeno. Ponoven zagon
  postopka istega zapisa ne pretvori dvakrat, ker obdela samo vrstice z RawValue IS NULL.

  Manjkajoci prevodi niso napaka in ne ustavijo zajema: vrednost ostane taka, kot je
  prisla, zapise pa se v map.MissingTranslation — to je delovni seznam, kaj je treba
  se prevesti, ne dnevnik napak.
*/

SET XACT_ABORT ON;

/* --- 1) slovar vrednosti -------------------------------------------------- */

IF OBJECT_ID(N'map.ValueLookup', N'U') IS NULL
BEGIN
  CREATE TABLE map.ValueLookup
  (
    ValueLookupId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ValueLookup PRIMARY KEY,
    /* Domain je koda lastnosti (npr. 'Prevladujoca barva SLO'); '*' pomeni "velja povsod".
       Ozja domena premaga '*' — tako se resijo primeri, kjer je "black" enkrat "crna"
       (barva) in drugic "crn" (material). */
    Domain nvarchar(200) NOT NULL CONSTRAINT DF_ValueLookup_Domain DEFAULT (N'*'),
    SourceValue nvarchar(400) NOT NULL,
    Language nvarchar(10) NOT NULL,
    TargetValue nvarchar(400) NOT NULL,
    Note nvarchar(400) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ValueLookup_IsActive DEFAULT (1),
    SourceKey AS LOWER(LTRIM(RTRIM(SourceValue))) PERSISTED,
    CONSTRAINT UQ_ValueLookup UNIQUE (Domain, SourceValue, Language)
  );
  CREATE INDEX IX_ValueLookup_Key ON map.ValueLookup (Language, SourceKey, Domain)
    INCLUDE (TargetValue, IsActive);
END;

/* --- 2) pretvorbe nad posamezno preslikavo -------------------------------- */

IF OBJECT_ID(N'map.FieldTransform', N'U') IS NULL
BEGIN
  CREATE TABLE map.FieldTransform
  (
    FieldTransformId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_FieldTransform PRIMARY KEY,
    FieldMappingId int NOT NULL,
    StepOrder int NOT NULL CONSTRAINT DF_FieldTransform_StepOrder DEFAULT (1),
    TransformCode nvarchar(20) NOT NULL,
    Argument nvarchar(400) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_FieldTransform_IsActive DEFAULT (1),
    CONSTRAINT UQ_FieldTransform UNIQUE (FieldMappingId, StepOrder),
    CONSTRAINT FK_FieldTransform_FieldMapping FOREIGN KEY (FieldMappingId)
      REFERENCES map.FieldMapping (FieldMappingId),
    CONSTRAINT CK_FieldTransform_Code CHECK (TransformCode IN
      (N'TRIM', N'NUMBER', N'UNIT', N'PREFIX', N'STRIPPREFIX', N'BOOL', N'UPPER', N'LOWER', N'LOOKUP'))
  );
END;

/* --- 3) delovni seznam manjkajocih prevodov ------------------------------- */

IF OBJECT_ID(N'map.MissingTranslation', N'U') IS NULL
BEGIN
  CREATE TABLE map.MissingTranslation
  (
    MissingTranslationId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_MissingTranslation PRIMARY KEY,
    Domain nvarchar(200) NOT NULL,
    Language nvarchar(10) NOT NULL,
    SourceValue nvarchar(400) NOT NULL,
    SeenCount int NOT NULL CONSTRAINT DF_MissingTranslation_SeenCount DEFAULT (0),
    FirstSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_MissingTranslation_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_MissingTranslation_LastSeenUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_MissingTranslation UNIQUE (Domain, Language, SourceValue)
  );
END;

/* --- 4) izvorna vrednost se ohrani --------------------------------------- */

IF COL_LENGTH(N'map.ExtractedValue', N'RawValue') IS NULL
  ALTER TABLE map.ExtractedValue ADD RawValue nvarchar(max) NULL;

/* --- 5) postopek ---------------------------------------------------------
   Mnozicen, ne po vrsticah: en UPDATE na korak, ne en na zapis. Korakov je toliko,
   kolikor je najvecji StepOrder — v praksi dva. Migracija 044 je zajem spravila iz
   sedmih ur v poldrugo minuto in ta postopek te pridobitve ne sme zapraviti. */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ApplyValueTransforms
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  CREATE TABLE #Scope
  (
    ExtractedValueId bigint NOT NULL PRIMARY KEY,
    FieldMappingId int NOT NULL,
    /* Zacasna tabela nastane v tempdb in privzame njeno zbiranje (SQL_Latin1_General_CP1_CI_AS),
       baza PIM pa ima Slovenian_CI_AS. Brez COLLATE DATABASE_DEFAULT primerjava z
       map.ValueLookup.Domain pade z napako 468. */
    Domain nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL
  );

  INSERT #Scope (ExtractedValueId, FieldMappingId, Domain)
  SELECT value.ExtractedValueId, value.FieldMappingId,
    CASE
      WHEN value.TargetFieldCode LIKE N''ProductAttribute.%''
        THEN SUBSTRING(value.TargetFieldCode, 18, 200)
      ELSE value.TargetFieldCode
    END
  FROM map.ExtractedValue value
  INNER JOIN raw.Inbox inbox ON inbox.InboxId = value.InboxId
  WHERE inbox.RunId = @RunId
    AND inbox.OrganizationId = @OrganizationId
    AND inbox.SourceCode = @SourceCode
    AND inbox.Status = N''Pending''
    AND value.Value IS NOT NULL
    AND value.RawValue IS NULL
    AND EXISTS
    (
      SELECT 1 FROM map.FieldTransform step
      WHERE step.FieldMappingId = value.FieldMappingId AND step.IsActive = 1
    );

  IF NOT EXISTS (SELECT 1 FROM #Scope) RETURN;

  /* Izvorna vrednost se shrani, preden jo kdo spremeni. */
  UPDATE value SET RawValue = value.Value
  FROM map.ExtractedValue value
  INNER JOIN #Scope scope ON scope.ExtractedValueId = value.ExtractedValueId;

  DECLARE @Step int = 1;
  DECLARE @MaxStep int =
  (
    SELECT MAX(step.StepOrder) FROM map.FieldTransform step
    WHERE step.IsActive = 1
      AND EXISTS (SELECT 1 FROM #Scope scope WHERE scope.FieldMappingId = step.FieldMappingId)
  );

  WHILE @Step <= ISNULL(@MaxStep, 0)
  BEGIN
    /* Vse pretvorbe razen slovarja: cisto racunanje nad nizom. */
    UPDATE value SET Value =
      CASE step.TransformCode
        WHEN N''TRIM''        THEN NULLIF(LTRIM(RTRIM(value.Value)), N'''')
        WHEN N''UPPER''       THEN UPPER(value.Value)
        WHEN N''LOWER''       THEN LOWER(value.Value)
        WHEN N''PREFIX''      THEN CONCAT(step.Argument, value.Value)
        WHEN N''STRIPPREFIX'' THEN
          CASE
            WHEN LTRIM(value.Value) LIKE step.Argument + N''%''
              THEN NULLIF(LTRIM(RTRIM(SUBSTRING(LTRIM(value.Value), LEN(step.Argument) + 1, 400))), N'''')
            ELSE value.Value
          END
        WHEN N''BOOL'' THEN
          CASE
            WHEN EXISTS
            (
              SELECT 1 FROM STRING_SPLIT(step.Argument, N'';'') part
              WHERE LOWER(LTRIM(RTRIM(part.value))) = LOWER(LTRIM(RTRIM(value.Value)))
            ) THEN N''1'' ELSE N''0''
          END
        WHEN N''NUMBER'' THEN number.Result
        WHEN N''UNIT''   THEN unit.Result
        ELSE value.Value
      END
    FROM map.ExtractedValue value
    INNER JOIN #Scope scope ON scope.ExtractedValueId = value.ExtractedValueId
    INNER JOIN map.FieldTransform step
      ON step.FieldMappingId = scope.FieldMappingId AND step.StepOrder = @Step AND step.IsActive = 1
    /* Mesto, kjer se stevilka konca in zacne enota: prvi znak, ki ni stevka,
       vejica, pika, presledek ali minus. Dodani ''x'' poskrbi, da ima cisto
       stevilcna vrednost tudi konec. */
    CROSS APPLY (SELECT Cut = NULLIF(PATINDEX(N''%[^0-9,. -]%'', value.Value + N''x''), 0)) mark
    CROSS APPLY (SELECT Result = NULLIF(LTRIM(RTRIM(REPLACE(LEFT(value.Value, mark.Cut - 1), N'','', N''.''))), N'''')) number
    CROSS APPLY (SELECT Result = NULLIF(LTRIM(RTRIM(SUBSTRING(value.Value, mark.Cut, 400))), N'''')) unit
    WHERE step.TransformCode <> N''LOOKUP'';

    /* Slovar. Ozja domena premaga ''*''. Ce prevoda ni, vrednost ostane nespremenjena. */
    UPDATE value SET Value = hit.TargetValue
    FROM map.ExtractedValue value
    INNER JOIN #Scope scope ON scope.ExtractedValueId = value.ExtractedValueId
    INNER JOIN map.FieldTransform step
      ON step.FieldMappingId = scope.FieldMappingId AND step.StepOrder = @Step
        AND step.IsActive = 1 AND step.TransformCode = N''LOOKUP''
    CROSS APPLY
    (
      SELECT TOP (1) lookup.TargetValue
      FROM map.ValueLookup lookup
      WHERE lookup.IsActive = 1
        AND lookup.Language = step.Argument
        AND lookup.SourceKey = LOWER(LTRIM(RTRIM(value.Value)))
        AND lookup.Domain IN (N''*'', scope.Domain)
      ORDER BY CASE WHEN lookup.Domain = N''*'' THEN 1 ELSE 0 END
    ) hit;

    /* Kar slovar ni znal prevesti, postane delovni seznam — enkrat na vrednost,
       ne enkrat na izdelek. */
    MERGE map.MissingTranslation AS target
    USING
    (
      SELECT scope.Domain, step.Argument AS Language,
             LEFT(LTRIM(RTRIM(value.Value)), 400) AS SourceValue, COUNT(*) AS SeenCount
      FROM map.ExtractedValue value
      INNER JOIN #Scope scope ON scope.ExtractedValueId = value.ExtractedValueId
      INNER JOIN map.FieldTransform step
        ON step.FieldMappingId = scope.FieldMappingId AND step.StepOrder = @Step
          AND step.IsActive = 1 AND step.TransformCode = N''LOOKUP''
      WHERE NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL
        AND NOT EXISTS
        (
          SELECT 1 FROM map.ValueLookup lookup
          WHERE lookup.IsActive = 1 AND lookup.Language = step.Argument
            AND lookup.SourceKey = LOWER(LTRIM(RTRIM(value.Value)))
            AND lookup.Domain IN (N''*'', scope.Domain)
        )
      GROUP BY scope.Domain, step.Argument, LEFT(LTRIM(RTRIM(value.Value)), 400)
    ) AS source
      ON target.Domain = source.Domain AND target.Language = source.Language
        AND target.SourceValue = source.SourceValue
    WHEN MATCHED THEN
      UPDATE SET SeenCount = target.SeenCount + source.SeenCount, LastSeenUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
      INSERT (Domain, Language, SourceValue, SeenCount)
      VALUES (source.Domain, source.Language, source.SourceValue, source.SeenCount);

    SET @Step = @Step + 1;
  END;

  DROP TABLE #Scope;
END;
');
