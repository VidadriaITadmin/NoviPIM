/*
  289 — Hitrejše branje atributov (intranet.GetAttributeDefinitions)

  Prenova strani 2026-09-26: /nastavitve/atributi se je nalagala 1,4 s, ker je postopek za vsak
  atribut posebej štel izdelke v canon.ProductAttribute (OUTER APPLY). Zdaj je to eno skupinsko
  štetje (izmerjeno 23 ms). Izhod postopka je enak: isti stolpci, iste vrednosti.
  Definicija je živa definicija iz baze z zamenjanim samo tem delom.

  Ročnega koraka ni. Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269 THROW 52890, N'289: datoteka ni prebrana kot UTF-8 (šumniki).', 1;
IF OBJECT_ID(N'intranet.GetAttributeDefinitions', N'P') IS NULL
  THROW 52891, N'289 potrebuje intranet.GetAttributeDefinitions (123).', 1;

EXEC(N'CREATE OR ALTER   PROCEDURE intranet.GetAttributeDefinitions
  @Iskanje nvarchar(200) = NULL,
  @SamoEnote bit = 0,
  @SamoBrezVira bit = 0,
  @SamoBrezPara bit = 0
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    definicija.AttributeCode,
    ime.Name AS AttributeName,
    definicija.AttributeGroup,
    definicija.DataType,
    definicija.Unit,
    definicija.IsTranslatable,
    definicija.IsUnitCandidate,
    definicija.UnitOfAttributeCode,
    definicija.IsActive,
    ISNULL(viri.Virov, 0) AS SourceCount,
    viri.Seznam AS SourceList,
    ISNULL(uporaba.Izdelkov, 0) AS ProductCount,
    prevodi.Json AS TranslationsJson,
    (SELECT COUNT(DISTINCT LanguageCode) FROM canon.Language WHERE IsActive = 1) AS LanguageCount
  FROM canon.AttributeDefinition definicija
  LEFT JOIN canon.AttributeTranslation ime
    ON ime.AttributeCode = definicija.AttributeCode AND ime.LanguageCode = N''sl''
  OUTER APPLY
  (
    SELECT (SELECT p.LanguageCode AS lang, p.Name AS name
            FROM canon.AttributeTranslation p
            WHERE p.AttributeCode = definicija.AttributeCode
            ORDER BY p.LanguageCode FOR JSON PATH) AS Json
  ) prevodi
  OUTER APPLY
  (
    SELECT COUNT(*) AS Virov, STRING_AGG(x.SourceCode, N'', '') AS Seznam
    FROM (SELECT DISTINCT SourceCode FROM map.AttributeMap
          WHERE AttributeCode = definicija.AttributeCode AND IsActive = 1) x
  ) viri
  LEFT JOIN
  (
    /* Stevec se bere po slovenskem imenu, ker canon.ProductAttribute se hrani ime in ne kode.
       289: eno skupinsko stetje namesto stetja na vrstico (1,4 s -> ~0,05 s). */
    SELECT vrednost.AttributeCode, COUNT_BIG(DISTINCT vrednost.ProductId) AS Izdelkov
    FROM canon.ProductAttribute vrednost
    GROUP BY vrednost.AttributeCode
  ) uporaba ON uporaba.AttributeCode = ime.Name
  WHERE (@Iskanje IS NULL
         OR definicija.AttributeCode LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(ime.Name, N'''') LIKE N''%'' + @Iskanje + N''%'')
    AND (@SamoEnote = 0 OR definicija.IsUnitCandidate = 1)
    AND (@SamoBrezVira = 0 OR ISNULL(viri.Virov, 0) = 0)
    AND (@SamoBrezPara = 0 OR (definicija.IsUnitCandidate = 1 AND definicija.UnitOfAttributeCode IS NULL))
  ORDER BY ISNULL(uporaba.Izdelkov, 0) DESC, definicija.AttributeCode;
END;');
