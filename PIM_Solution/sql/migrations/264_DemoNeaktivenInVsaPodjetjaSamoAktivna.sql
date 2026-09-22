/*
  264 — DEMO ni več aktivno podjetje; »vsa podjetja« pomeni samo aktivna podjetja.

  Uporabnik 2026-09-22: DEMO se ne sme več gledati ne prikazovati. Samo IsActive = 0 tega ne
  naredi: izbirniki podjetij in avtomatika (AutomationStore.GetActiveOrganizationsAsync) ga sicer
  izpustijo, bralne procedure v načinu »vsa podjetja« (@OrganizationId IS NULL) pa so brale
  kar vse vrstice, zato bi seznam izdelkov, števci zavihkov, kakovost po kategorijah, zaloga,
  stranke in kandidati še naprej šteli DEMO (17.425 artiklov).

  Popravek:
    1. dbo.OrganizationConfig: DEMO → IsActive = 0 (podatki ostanejo, nič se ne briše; ponovni
       vklop je en UPDATE).
    2. V bralnih procedurah se pogoj »@OrganizationId IS NULL OR x.OrganizationId = @OrganizationId«
       spremeni v »(@OrganizationId IS NULL AND x.OrganizationId IN (aktivna podjetja)) OR ...«.
       Izrecno izbrano podjetje ostane kot prej. Dolge procedure se popravijo z REPLACE nad živo
       definicijo (kot 262), da se ne povozi vzporedno uveljavljenih sprememb.
    3. Enako v val.RunValidation: validacija vseh podjetij ne preverja več neaktivnih. Odprte
       težave DEMO ostanejo zapisane, a jih noben pogled »vsa podjetja« ne pokaže.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

BEGIN TRANSACTION;

UPDATE dbo.OrganizationConfig SET IsActive = 0 WHERE Name = N'DEMO' AND IsActive = 1;

DECLARE @Aktivna nvarchar(200) =
  N' IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */';

DECLARE @Zamenjava TABLE (Vrstni int IDENTITY, Staro nvarchar(400) NOT NULL, Novo nvarchar(800) NOT NULL);
INSERT @Zamenjava (Staro, Novo)
SELECT N'@OrganizationId IS NULL OR ' + stolpec + enako + N'@OrganizationId',
       N'(@OrganizationId IS NULL AND ' + stolpec + @Aktivna + N') OR ' + stolpec + enako + N'@OrganizationId'
FROM (VALUES (N'product.OrganizationId'), (N'izdelek.OrganizationId'), (N'customer.OrganizationId'),
             (N'snapshot.OrganizationId'), (N'candidate.OrganizationId'), (N'OrganizationId')) AS izbor(stolpec)
CROSS JOIN (VALUES (N' = '), (N'=')) AS zapis(enako);

DECLARE @Postopki TABLE (Ime sysname NOT NULL);
INSERT @Postopki (Ime) VALUES
  (N'intranet.GetCategoryTree'), (N'intranet.GetCustomerList'), (N'intranet.GetProductList'),
  (N'intranet.GetProductListFilters'), (N'intranet.GetProductListViews'), (N'intranet.GetQualityByCategory'),
  (N'intranet.GetQualityProducts'), (N'intranet.GetStockByItem'), (N'intranet.GetStockOverview'),
  (N'intranet.GetStockPositions'), (N'intranet.GetSupplierProductCandidates'),
  /* Validacija brez podjetja (urnik, shranjevanje pravila) ne preverja več neaktivnih podjetij. */
  (N'val.RunValidation');

DECLARE @Ime sysname, @Definicija nvarchar(max), @Staro nvarchar(400), @Novo nvarchar(800), @Sporocilo nvarchar(400);
DECLARE postopek CURSOR LOCAL FAST_FORWARD FOR SELECT Ime FROM @Postopki;
OPEN postopek;
FETCH NEXT FROM postopek INTO @Ime;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Definicija = OBJECT_DEFINITION(OBJECT_ID(@Ime));
  IF @Definicija IS NULL
  BEGIN
    SET @Sporocilo = N'264: postopek ' + @Ime + N' ne obstaja.';
    THROW 52640, @Sporocilo, 1;
  END;

  IF CHARINDEX(N'/* 264 */', @Definicija) = 0
  BEGIN
    DECLARE zamenjava CURSOR LOCAL FAST_FORWARD FOR SELECT Staro, Novo FROM @Zamenjava ORDER BY Vrstni;
    OPEN zamenjava;
    FETCH NEXT FROM zamenjava INTO @Staro, @Novo;
    WHILE @@FETCH_STATUS = 0
    BEGIN
      SET @Definicija = REPLACE(@Definicija, @Staro, @Novo);
      FETCH NEXT FROM zamenjava INTO @Staro, @Novo;
    END;
    CLOSE zamenjava;
    DEALLOCATE zamenjava;

    IF CHARINDEX(N'/* 264 */', @Definicija) = 0
    BEGIN
      SET @Sporocilo = N'264: v ' + @Ime + N' ni pogoja »vsa podjetja«.';
      THROW 52641, @Sporocilo, 1;
    END;

    SET @Definicija = STUFF(@Definicija, CHARINDEX(N'CREATE', @Definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
    EXEC (@Definicija);
  END;

  -- Noben pogoj »vsa podjetja« ne sme ostati brez omejitve na aktivna podjetja.
  IF PATINDEX(N'%@OrganizationId IS NULL OR%', OBJECT_DEFINITION(OBJECT_ID(@Ime))) > 0
  BEGIN
    SET @Sporocilo = N'264: ' + @Ime + N' ima še pogoj »vsa podjetja« brez omejitve na aktivna.';
    THROW 52642, @Sporocilo, 1;
  END;

  FETCH NEXT FROM postopek INTO @Ime;
END;
CLOSE postopek;
DEALLOCATE postopek;

IF EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE Name = N'DEMO' AND IsActive = 1)
  THROW 52643, N'264: DEMO je še aktiven.', 1;

COMMIT TRANSACTION;
