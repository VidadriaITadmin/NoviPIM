/*
  123 — bralna modela za register in sifrant atributov.

  Register (121) in sifrant (122) sta podatek; ta migracija ju naredi berljiva. Urejanje in
  vmesnik sta locen korak - najprej mora biti vidno, kaj je, sele nato se to popravlja.

  Stran /nastavitve/atributi ima danes tri filtre, ki so onemogoceni z besedilom "bralni model
  manjka". To sta postopka, ki ju je pogresala.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSourceAttributes
  @SourceCode nvarchar(100) = NULL,
  @Stanje nvarchar(20) = NULL,      /* NULL = vse, ''Nepreslikano'', ''Preslikano'', ''Ugasnjeno'' */
  @Iskanje nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /*
    Ena vrstica na (vir, izvorni atribut). Register pove, kaj je vir poslal in koliko izdelkov je
    za tem; preslikava pove, ali ima to cilj pri nas. Vrstica brez cilja ni napaka, ampak naloga.
  */
  WITH Osnova AS
  (
    SELECT
      registrirano.SourceCode,
      registrirano.SourceAttributeName,
      registrirano.SourceLabel,
      registrirano.SampleValue,
      registrirano.SampleUnit,
      registrirano.ProductCount,
      registrirano.LastSeenUtc,
      preslikava.AttributeCode,
      preslikava.LanguageCode,
      preslikava.IsUnit,
      preslikava.IsActive AS MapIsActive,
      preslikava.UpdatedUtc,
      preslikava.UpdatedBy,
      ime.Name AS AttributeName,
      CASE WHEN preslikava.AttributeMapId IS NULL THEN N''Nepreslikano''
           WHEN preslikava.IsActive = 0 THEN N''Ugasnjeno''
           ELSE N''Preslikano'' END AS Stanje
    FROM map.SourceAttribute registrirano
    LEFT JOIN map.AttributeMap preslikava
      ON preslikava.SourceCode = registrirano.SourceCode
     AND preslikava.SourceAttributeName = registrirano.SourceAttributeName
    LEFT JOIN canon.AttributeTranslation ime
      ON ime.AttributeCode = preslikava.AttributeCode AND ime.LanguageCode = N''sl''
    WHERE (@SourceCode IS NULL OR registrirano.SourceCode = @SourceCode)
  )
  SELECT *
  FROM Osnova
  WHERE (@Stanje IS NULL OR Stanje = @Stanje)
    AND (@Iskanje IS NULL
         OR SourceAttributeName LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(SourceLabel, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(AttributeName, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(AttributeCode, N'''') LIKE N''%'' + @Iskanje + N''%'')
  ORDER BY ProductCount DESC, SourceCode, SourceAttributeName;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetAttributeDefinitions
  @Iskanje nvarchar(200) = NULL,
  @SamoEnote bit = 0,
  @SamoBrezVira bit = 0
AS
BEGIN
  SET NOCOUNT ON;
  /*
    Sifrant z odgovorom na dve vprasanji, ki ju je pred 122 postavljal vsakdo posebej: kateri
    viri ta atribut sploh polnijo in koliko izdelkov ga ima.

    Stevec izdelkov se bere po SLOVENSKEM imenu, ker canon.ProductAttribute se vedno hrani ime
    in ne kode. Ko bo vrednost prenesena na kodo, bo ta spoj odvec - do takrat je edini posten.
  */
  SELECT
    definicija.AttributeCode,
    ime.Name AS AttributeName,
    definicija.AttributeGroup,
    definicija.DataType,
    definicija.Unit,
    definicija.IsTranslatable,
    definicija.IsUnitCandidate,
    definicija.IsActive,
    ISNULL(viri.Virov, 0) AS SourceCount,
    viri.Seznam AS SourceList,
    ISNULL(uporaba.Izdelkov, 0) AS ProductCount,
    (SELECT COUNT(*) FROM canon.AttributeTranslation p WHERE p.AttributeCode = definicija.AttributeCode) AS Translations
  FROM canon.AttributeDefinition definicija
  LEFT JOIN canon.AttributeTranslation ime
    ON ime.AttributeCode = definicija.AttributeCode AND ime.LanguageCode = N''sl''
  OUTER APPLY
  (
    SELECT COUNT(DISTINCT preslikava.SourceCode) AS Virov,
           STRING_AGG(preslikava.SourceCode, N'', '') AS Seznam
    FROM (SELECT DISTINCT SourceCode FROM map.AttributeMap
          WHERE AttributeCode = definicija.AttributeCode AND IsActive = 1) preslikava
  ) viri
  OUTER APPLY
  (
    SELECT COUNT_BIG(DISTINCT vrednost.ProductId) AS Izdelkov
    FROM canon.ProductAttribute vrednost
    WHERE vrednost.AttributeCode = ime.Name
       OR vrednost.AttributeCode = ime.Name + N'' SLO''
       OR vrednost.AttributeCode = ime.Name + N'' ANG''
  ) uporaba
  WHERE (@Iskanje IS NULL
         OR definicija.AttributeCode LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(ime.Name, N'''') LIKE N''%'' + @Iskanje + N''%'')
    AND (@SamoEnote = 0 OR definicija.IsUnitCandidate = 1)
    AND (@SamoBrezVira = 0 OR ISNULL(viri.Virov, 0) = 0)
  ORDER BY ISNULL(uporaba.Izdelkov, 0) DESC, definicija.AttributeCode;
END;
');
