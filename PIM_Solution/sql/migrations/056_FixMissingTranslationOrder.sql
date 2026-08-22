/*
  056 — seznam manjkajocih prevodov je belezil prevode namesto izvirnikov.

  Napaka iz 049: v postopku map.ApplyValueTransforms je MERGE v map.MissingTranslation
  stal *za* UPDATE-om, ki prevod uveljavi. Oba berta isti stolpec value.Value, zato je
  MERGE videl ze prevedeno vrednost in preveril, ali obstaja prevod za prevod. Za vsako
  uspesno prevedeno vrednost je zato v delovni seznam pripisal slovensko besedo:
  ''Living room'' se je pravilno prevedlo v ''Dnevna soba'', v seznamu manjkajocih pa je
  pristalo ''Dnevna soba''.

  Popravek je vrstni red: najprej se zabelezi, cesar slovar ne zna, sele nato se prevod
  uveljavi. Postopek je sicer nespremenjen.

  Ociscenje: iz map.MissingTranslation se odstranijo samo tiste vrstice, za katere je
  dokazljivo, da so posledica te napake — SourceValue je enak TargetValue kaksnega
  aktivnega vpisa v slovarju za isti jezik, torej gre za prevod in ne za izvirnik.
  Vrstice, ki so resnicno manjkajoci prevodi, ostanejo; karkoli bi bilo pobrisano po
  nesreci, naslednji zajem tako ali tako zapise znova, ker se seznam izpeljuje iz podatkov.
*/

SET XACT_ABORT ON;

DELETE manjkajoc
FROM map.MissingTranslation manjkajoc
WHERE EXISTS
(
  SELECT 1 FROM map.ValueLookup slovar
  WHERE slovar.IsActive = 1
    AND slovar.Language = manjkajoc.Language
    AND slovar.TargetValue = manjkajoc.SourceValue
);

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

    /* Najprej delovni seznam, sele nato prevod: MERGE bere value.Value, in ce bi tekel
       za UPDATE-om, bi gledal ze prevedeno vrednost. Tako je 049 v seznam manjkajocih
       vpisoval prevode same (''Dnevna soba'' namesto ''Living room''). */
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

    SET @Step = @Step + 1;
  END;

  DROP TABLE #Scope;
END;
');
