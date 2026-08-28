/*
  127 — bralna podlaga za izvoz izdelkov v Excel z ERP, komercialnimi in spletnimi podatki.

  Zahteva uporabnika 2026-08-28:

    »Izvoz excel smo rekli da mu manjkajo polja ERP morajo biti, komerciala in splet ...
     ostala polja so mogoče moteča in se jih lahko odstrani«
    »v excelu bi bilo fino da se obarvajo polja katera manjkajo pri izdelkih z tako blago
     vinjsko rdečo ... Potem z rumenkasto pa označimo polja katera so nujna za validacijo«

  Dosedanji izvoz »pregled« je bil prepis zaslonskega seznama: stanja in stevci, nobene
  vsebine izdelka. Zvezek zato ni bil uporaben za mnozicno popravljanje, ki je edini razlog,
  da kdo izvaza 20.000 vrstic v Excel.

  Ta migracija ne doda nobene tabele in nicesar ne pise. Doda eno bralno proceduro, ki v enem
  klicu vrne dvoje:

    1) vrednosti polj za dane izdelke iz pogleda canon.FieldValue, omejene na sezname kod, ki
       jih zvezek res izpise. Filter po seznamu kod je nujen: brez njega bi 20.000 izdelkov
       potegnilo tudi vsak atribut in vsako kategorijo, torej milijone vrstic za nic.

    2) register zahtevanih polj — katera polja so pogoj za validacijo in ali blokirajo ERP ali
       splet. To je edini posten vir za rumeno oznako v zvezku; seznam v kodi bi se z registrom
       slej ko prej razsel.

  Vec vrstic na isto kodo (kategorije, mediji) se zdruzi v eno vrednost, loceno s podpicjem,
  in prestejejo se. Zvezek ima en stolpec na polje; sicer bi sirina lista bila odvisna od
  izdelka z najvec slikami.

  Procedura je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductExportSheet
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  DECLARE @Fields TABLE (FieldCode nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @Fields (FieldCode)
  SELECT DISTINCT CONVERT(nvarchar(200), parsed.value) FROM OPENJSON(@FieldCodesJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND NULLIF(LTRIM(RTRIM(parsed.value)), N'''') IS NOT NULL;

  /* 1) Vrednosti. Vec vrstic na isto kodo se zdruzi; zvezek ima en stolpec na polje. */
  SELECT
    fieldValue.ProductId,
    fieldValue.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), fieldValue.Value), N''; '') WITHIN GROUP (ORDER BY fieldValue.Value),
    ValueCount = COUNT(*)
  FROM canon.FieldValue AS fieldValue
  INNER JOIN @Products AS product ON product.ProductId = fieldValue.ProductId
  INNER JOIN @Fields AS field ON field.FieldCode = fieldValue.FieldCode
  WHERE fieldValue.Value IS NOT NULL
  GROUP BY fieldValue.ProductId, fieldValue.FieldCode;

  /* 2) Register zahtevanih polj. Rumena oznaka v zvezku izhaja iz tega, ne iz seznama v kodi. */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 1 ELSE 0 END)),
    BlocksWeb = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 0 ELSE 1 END)),
    Severity = MIN(requirement.Severity),
    Profiles = STRING_AGG(validationProfile.ProfileCode, N'', '') WITHIN GROUP (ORDER BY validationProfile.ProfileCode)
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  INNER JOIN out.ExportProfile AS exportProfile
    ON exportProfile.ExportProfileId = validationProfile.ExportProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
  GROUP BY requirement.FieldCode;
END;');
