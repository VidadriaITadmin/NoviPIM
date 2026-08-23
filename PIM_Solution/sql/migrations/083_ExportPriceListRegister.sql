/*
  083 — kateri cenik je B2B in kateri B2C, pove register, ne koda.

  Kaj je bilo narobe. MagentoExportCommand je bral ceno takole:

      FROM pim.ProductPrice WHERE PriceList = N'B2B'   -- oziroma N'B2C'

  Sifra cenika je bila torej zapisana v programu. Vsako podjetje pa svoje cenike imenuje
  po svoje, in izmerjeno 2026-08-23 nad objavljenim slojem:

      DEMO (1)        B2B 1.109,  B2C 3,      NAB 1.665, PRC 7
      IQLighting (2)  B2C 43.218, LOM 24.914, NAB 6.833, PRC 3.288, EGL 3.126,
                      BTT 1.880,  IDE 1.156,  ACB 20      -- cenika B2B sploh NI
      Vidadria (3)    B2B 9.691,  B2C 9.758   + 16 drugih
      Ediito (4)      B2B 33.315, LOM 24.914, NAB 3.185, ACB 2.212, PRC 390
                                                          -- cenika B2C sploh NI

  Posledica v izvozu: IQLighting ima stolpec "Cena B2B" prazen pri vseh 43.503 izdelkih,
  Ediito pa "Cena B2C" pri vseh 33.304. To ni napaka podatka — je nastavitev podjetja,
  zapisana na napacnem mestu.

  Vzorec je isti kot pri glavah stolpcev (045), spletnih straneh (059) in skladiscih (064):
  kar je odvisno od podjetja, je vrstica v registru.

  Kaj nastane:
    out.ExportPriceList   za podjetje in kanonicno kodo cenovnega stolpca pove, iz katerega
                          cenika se bere; SortOrder je prednost, ce jih je vec.

  Seme namenoma ne odloca nicesar. Vpise natanko to, kar je danes v kodi — B2B -> "Cena B2B",
  B2C -> "Cena B2C" za vsa stiri podjetja — zato je izvoz po tej migraciji do zadnjega znaka
  enak kot pred njo. Kateri od osmih cenikov IQLightinga je B2B in kateri cenik Ediita je
  B2C, je poslovna odlocitev in ne sodi v migracijo; ko bo znana, je to en INSERT in nobena
  sprememba programa.

  Prazen register za podjetje NI napaka: pomeni "to podjetje tega cenika nima" in stolpec
  ostane prazen — natanko tako, kot je danes pri IQLightingu in Ediitu. Zato izvoz ob
  manjkajoci vrstici ne pade; pade samo ob manjkajocem profilu (045), ker je profil oblika
  datoteke, cenik pa njena vsebina.
*/

SET XACT_ABORT ON;

/* --- 1) register cenikov po podjetju ---------------------------------------- */

IF OBJECT_ID(N'out.ExportPriceList') IS NULL
BEGIN
  CREATE TABLE out.ExportPriceList
  (
    ExportPriceListId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExportPriceList PRIMARY KEY,
    OrganizationId int NOT NULL,
    /* Kanonicna koda cenovnega stolpca izvoza, ista kot v out.ExportColumn.CanonicalFieldCode. */
    PriceFieldCode nvarchar(100) NOT NULL,
    /* Sifra cenika, kot jo pripelje SAOP v pim.ProductPrice.PriceList. */
    PriceListCode nvarchar(50) NOT NULL,
    /* Prednost, kadar je za isti stolpec vec cenikov: manjse gre prej. Izvoz vzame prvi
       cenik po tem vrstnem redu, ki ima za izdelek veljavno tekoco ceno. */
    SortOrder int NOT NULL CONSTRAINT DF_ExportPriceList_SortOrder DEFAULT(100),
    IsActive bit NOT NULL CONSTRAINT DF_ExportPriceList_IsActive DEFAULT(1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportPriceList_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExportPriceList UNIQUE (OrganizationId, PriceFieldCode, PriceListCode),
    CONSTRAINT FK_ExportPriceList_Organization FOREIGN KEY (OrganizationId)
      REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

/* --- 2) seme: natanko to, kar je bilo do zdaj v kodi ------------------------ */

/*
  Vrstica nastane za vsako podjetje iz dbo.OrganizationConfig, ne za nasteta stiri: novo
  podjetje mora dobiti isto privzeto vedenje, kot ga je imelo v kodi, brez nove migracije.
  Kjer podjetje cenika s to sifro nima, vrstica nicesar ne pokvari — stolpec ostane prazen
  tako kot danes.
*/
INSERT out.ExportPriceList (OrganizationId, PriceFieldCode, PriceListCode, SortOrder, IsActive)
SELECT organization.OrganizationId, seed.PriceFieldCode, seed.PriceListCode, 10, 1
FROM dbo.OrganizationConfig organization
CROSS JOIN (VALUES
  (N'Product.PriceB2B', N'B2B'),
  (N'Product.PriceB2C', N'B2C')
) AS seed(PriceFieldCode, PriceListCode)
WHERE NOT EXISTS (
  SELECT 1 FROM out.ExportPriceList existing
  WHERE existing.OrganizationId = organization.OrganizationId
    AND existing.PriceFieldCode = seed.PriceFieldCode
    AND existing.PriceListCode = seed.PriceListCode);

/* --- 3) dokaz ---------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM out.ExportPriceList WHERE PriceFieldCode = N'Product.PriceB2B' AND IsActive = 1)
  THROW 51083, N'083: register cenikov nima nobene aktivne vrstice za Product.PriceB2B.', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportPriceList WHERE PriceFieldCode = N'Product.PriceB2C' AND IsActive = 1)
  THROW 51083, N'083: register cenikov nima nobene aktivne vrstice za Product.PriceB2C.', 1;

/* Vsako podjetje ima obe vrstici — sicer bi eno tiho izgubilo cenovni stolpec. */
IF EXISTS (
  SELECT 1 FROM dbo.OrganizationConfig organization
  WHERE (SELECT COUNT(*) FROM out.ExportPriceList priceList
         WHERE priceList.OrganizationId = organization.OrganizationId) < 2)
  THROW 51083, N'083: vsaj eno podjetje nima obeh privzetih vrstic registra cenikov.', 1;
