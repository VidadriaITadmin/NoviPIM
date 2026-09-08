/*
  171 — delovni list izdelkov, ki ga je mogoce vrniti nazaj.

  Zahteva uporabnika 2026-09-08:

    »Tukaj preglej izvoz in pa uvoz artiklov na strani izdelki. Sepravi naredi enoten izvoz in
     pa uvoz da bo lahko uporabnik pisal podatke in jih uvozil notri ko jih spremeni in dopolni.
     Dodati bo treba se nekatera polja sploh pri spletu in pa na katero stran gre artikel
     (svetila ali videlektro ali oboje — to sem mislil imeti stolpec in notri pisati in
     locevati z znakom |)«

  Kaj je bilo do zdaj. Izvoz s strani /izdelki je imel dve predlogi. »Pregled« je nosil vsebino
  izdelka, a je bil enosmeren: naslovi kot »Naziv ERP (sl)« se pri uvozu ne ujamejo z nobeno
  kanonicno kodo, zato bi od cele datoteke prisla nazaj samo sifra. »Predloga SAOP« je bila
  vracljiva, a je nosila izkljucno ERP polja — brez spletnih nazivov, opisov, kategorij,
  atributov in brez podatka, na katero spletno stran artikel sploh gre. Uvoza spletnih podatkov
  ni bilo nikjer; edini uvoz v sistemu je polnil odhodno vrsto za SAOP.

  Kaj ta migracija doda:

    1. intranet.GetProductWorkbook — vse, kar delovni list potrebuje, v enem klicu: vrednosti
       polj, kategorije po spletnih straneh, atributi, slike, sifrant atributov in register
       zahtevanih polj. Sest rezultatov namesto sest klicev; pri 20.000 izdelkih je to razlika
       med sekundo in minuto.

    2. pim.SetProductWebPublish — zapisovalna pot za zastavico »Za splet«. Doslej je bila
       canon.Product.WebPublish samo brana: v izvozu je bila, spremeniti pa je ni bilo mogoce
       nikjer razen z rocnim UPDATE v bazi. Brez nje stolpec v listu ne bi imel ucinka.

  Cesar ta migracija namenoma NE naredi:

    - Ne uvaja nove tabele za »na katero stran gre artikel«. Ta podatek ze obstaja in ima svoje
      pravilo (146): stran S je izdelku dodeljena natanko takrat, kadar ima izdelek na S vsaj
      eno kategorijo. Nova vzporedna tabela bi bila drugi vir resnice za isto vprasanje in prvi
      dan, ko bi se razsla s kategorijami, bi se artikel na spletu pojavil ali izginil brez
      sledi. Stolpec »Spletne strani« v listu zato pise skozi obstojeco pim.SetProductCategories:
      stran, ki je v stolpcu ni, izgubi kategorije; stran, ki je v stolpcu je, jih mora dobiti.

    - Ne dotakne se out.GetExportRows in nobenega izvoznega profila. Pogodba do Magenta ostane,
      kot je bila.

  Vse je CREATE OR ALTER oziroma pogojno; migracija je ponovljiva.
*/

SET XACT_ABORT ON;

/* --- 1) Branje: vse za delovni list v enem klicu ------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
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

  /*
    1) Vrednosti polj. Filter po seznamu kod je nujen: brez njega bi 20.000 izdelkov poteglo
    tudi vsak atribut in vsako kategorijo, torej milijone vrstic za nic. Vec vrstic na isto
    kodo se zdruzi z » | «, ker je to locilo seznama v celotnem listu.
  */
  SELECT
    fieldValue.ProductId,
    fieldValue.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), fieldValue.Value), N'' | '') WITHIN GROUP (ORDER BY fieldValue.Value)
  FROM canon.FieldValue AS fieldValue
  INNER JOIN @Products AS product ON product.ProductId = fieldValue.ProductId
  INNER JOIN @Fields AS field ON field.FieldCode = fieldValue.FieldCode
  WHERE fieldValue.Value IS NOT NULL
  GROUP BY fieldValue.ProductId, fieldValue.FieldCode;

  /*
    2) Kategorije po spletnih straneh. Stolpec »Spletne strani« se v listu izracuna iz tega:
    stran, ki tu ni omenjena, izdelku ni dodeljena (pravilo migracije 146).
  */
  SELECT
    category.ProductId,
    category.WebSite,
    CategoryPaths = STRING_AGG(CONVERT(nvarchar(max), category.CategoryPath), N'' | '') WITHIN GROUP (ORDER BY category.CategoryPath)
  FROM canon.ProductCategory AS category
  INNER JOIN @Products AS product ON product.ProductId = category.ProductId
  GROUP BY category.ProductId, category.WebSite;

  /* 3) Atributi. Gola koda brez jezika je vrednost, ki velja za vse jezike. */
  SELECT
    attributeValue.ProductId,
    attributeValue.AttributeCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), attributeValue.Value), N'' | '') WITHIN GROUP (ORDER BY attributeValue.Value)
  FROM canon.ProductAttribute AS attributeValue
  INNER JOIN @Products AS product ON product.ProductId = attributeValue.ProductId
  WHERE attributeValue.Value IS NOT NULL
  GROUP BY attributeValue.ProductId, attributeValue.AttributeCode;

  /* 4) Slike. V listu so samo za branje; urejajo se na strani /mediji. */
  SELECT
    media.ProductId,
    Urls = STRING_AGG(CONVERT(nvarchar(max), media.Url), N'' | '') WITHIN GROUP (ORDER BY media.SortOrder)
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  GROUP BY media.ProductId;

  /*
    5) Sifrant atributov za naslove stolpcev: kar ti izdelki ze imajo, in kar od njih zahteva
    validacija. Atribut, ki ga zahteva validacija in ga izdelek nima, mora dobiti stolpec —
    sicer manjkajoce vrednosti ni mogoce vpisati.
  */
  SELECT
    codes.AttributeCode,
    Name = ISNULL(translation.Name, codes.AttributeCode),
    IsRequired = CONVERT(bit, MAX(codes.IsRequired))
  FROM
  (
    SELECT DISTINCT AttributeCode = attributeValue.AttributeCode, IsRequired = 0
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN @Products AS product ON product.ProductId = attributeValue.ProductId
    UNION ALL
    SELECT DISTINCT
      AttributeCode = SUBSTRING(requirement.FieldCode, 18, 200),
      IsRequired = 1
    FROM val.FieldRequirement AS requirement
    INNER JOIN val.ValidationProfile AS validationProfile
      ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
      AND requirement.FieldCode LIKE N''ProductAttribute.%''
      AND CHARINDEX(N''.'', SUBSTRING(requirement.FieldCode, 18, 200)) = 0
  ) AS codes
  LEFT JOIN canon.AttributeTranslation AS translation
    ON translation.AttributeCode = codes.AttributeCode AND translation.LanguageCode = N''sl''
  WHERE NULLIF(LTRIM(RTRIM(codes.AttributeCode)), N'''') IS NOT NULL
  GROUP BY codes.AttributeCode, translation.Name;

  /*
    6) Register zahtevanih polj. Rumena glava in rdeca celica v listu izhajata iz tega, ne iz
    seznama v kodi; seznam bi se z registrom slej ko prej razsel.
  */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 1 ELSE 0 END)),
    BlocksWeb = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 0 ELSE 1 END))
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  INNER JOIN out.ExportProfile AS exportProfile
    ON exportProfile.ExportProfileId = validationProfile.ExportProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
  GROUP BY requirement.FieldCode;
END;');

/* --- 2) Pisanje: zastavica »Za splet« ------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE pim.SetProductWebPublish
  @OrganizationId int,
  @ItemID nvarchar(200),
  @WebPublish bit,
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 106001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @ProductId bigint = NULL, @Old bit = NULL;
  SELECT @ProductId = ProductId, @Old = WebPublish FROM canon.Product
  WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
  IF @ProductId IS NULL
    THROW 106005, N''Izdelka s to sifro v tem podjetju ni.'', 1;

  IF @Old = @WebPublish
  BEGIN
    SELECT Outcome = N''Unchanged'', ProductId = @ProductId;
    RETURN;
  END

  /*
    Zgodovino zapise sprozilec nad canon.Product (028); ta procedura mu samo pove, kdo pise in
    zakaj. Brez konteksta bi sprememba pristala v svezenj brez lastnika.
  */
  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    UPDATE canon.Product SET WebPublish = @WebPublish WHERE ProductId = @ProductId;
  END TRY
  BEGIN CATCH
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;
  EXEC val.RunValidation @OrganizationId = @OrganizationId, @ProductId = @ProductId;

  SELECT Outcome = N''Updated'', ProductId = @ProductId;
END;');

/* --- 3) Dokaz, da je migracija naredila, kar pise ------------------------------------------ */

IF OBJECT_ID(N'intranet.GetProductWorkbook', N'P') IS NULL
  THROW 51710, N'171: intranet.GetProductWorkbook manjka.', 1;
IF OBJECT_ID(N'pim.SetProductWebPublish', N'P') IS NULL
  THROW 51711, N'171: pim.SetProductWebPublish manjka.', 1;
