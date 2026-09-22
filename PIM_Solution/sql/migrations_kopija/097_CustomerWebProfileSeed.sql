/*
  097 — profil stranke za splet: vrstica za vsako stranko in delovni seznam odlocitev.

  Odlocitev uporabnika 2026-08-24: "tipa stranke ali je kupec, trgovec ali oboje bo potrebno da
  uporabnik sam doloci, tako da to bo dodatni stolpec. Zdej za poslovno enoto ima ponavadi v
  nazivu PE poleg; je treba omogociti, da uporabnik sam doloci, kdo je poslovna enota in pa
  tranzit."

  Torej: tip stranke in PE/tranzit nista podatek iz SAOP, ampak PIM-lastni polji, ki ju postavi
  clovek. Merjeno 2026-08-24 to tudi drzi — SAOP posilja CustomerType O/K/S/D (vrsta partnerja)
  in EntityType P/F (pravna/fizicna oseba), poslovne taksonomije pa ne; CompanyLinkType ima pri
  vseh 4.683 strankah vrednost I in za PE/tranzit ni uporaben.

  --- Kaj ta migracija naredi -------------------------------------------------------------

  1. pim.CustomerWebProfile dobi stolpec PayerKind (PE / TRANZIT). Dokument o pravilih (§4.10)
     na njem stoji: poslovna enota podeduje osnovne popuste od placnika, tranzit jih ne prikaze.

  2. pim.PromoteCustomerWebProfile ustvari vrstico profila za vsako aktivno stranko. Postopek je
     namenoma "prazen": iz SAOP prepise samo to, kar SAOP res ve (CustomerKind iz pravne oblike),
     odlocitev cloveka pa se NE dotakne — ce je CustomerTypeCode ali PayerKind ze postavljen,
     ostane. Zato ga je varno pognati vsako noc.

     WebEnabled ostane 0, dokler stranka nima tipa. To ni previdnost, ampak pravilo iz dokumenta:
     skupina strank je nosilna vez za vse cene in popuste, zato stranka brez tipa v izvoz ne sme.
     out.ExportB2bCustomersCsv ze filtrira po WebEnabled = 1, torej izvoz ostane prazen, dokler
     odlocitev ni sprejeta — in se napolni sam, ko je.

  3. pim.CustomerWebProfileToDecide — delovni seznam za cloveka: katera stranka se nima tipa in
     katera potrebuje PE/tranzit. Predlog za PE je izpeljan iz naziva ("PE" kot locena beseda),
     ker uporabnik pravi, da "ima ponavadi v nazivu PE poleg". Predlog je predlog: v profil se ne
     zapise, dokler ga clovek ne potrdi.

     Odlocitev PE/tranzit je smiselna samo tam, kjer je placnik nekdo drug: takih strank je 1.273
     od 11.566. Ostale placujejo zase in vprasanja nimajo.

  Nicesar ne brise in nobene odlocitve ne sprejme.
*/

SET XACT_ABORT ON;

/* Stolpec in njegov CHECK morata biti locena paketa: v enem samem SQL Server prevede ves
   paket naenkrat in stolpca ob prevajanju CHECK-a se ni. Migracija tece kot en ukaz, zato
   locenost naredi EXEC. */
EXEC(N'
IF COL_LENGTH(''pim.CustomerWebProfile'', ''PayerKind'') IS NULL
  ALTER TABLE pim.CustomerWebProfile ADD PayerKind nvarchar(20) NULL;
');

EXEC(N'
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N''CK_CustomerWebProfile_PayerKind'')
  ALTER TABLE pim.CustomerWebProfile WITH CHECK ADD CONSTRAINT CK_CustomerWebProfile_PayerKind
    CHECK (PayerKind IS NULL OR PayerKind IN (N''PE'', N''TRANZIT''));
');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.PromoteCustomerWebProfile
  @OrganizationId int = NULL
AS
BEGIN
  /*
    Vrstica profila za vsako aktivno stranko. Iz SAOP pride samo CustomerKind (pravna oblika);
    tip stranke in PE/tranzit sta odlocitev cloveka in ju ta postopek nikoli ne prepise.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  MERGE pim.CustomerWebProfile AS target
  USING
  (
    SELECT stranka.CustomerId,
           CASE stranka.LegalForm WHEN N''P'' THEN N''Pravna oseba''
                                  WHEN N''F'' THEN N''Fizicna oseba'' END AS CustomerKind
    FROM b2b.Customer stranka
    WHERE stranka.IsActive = 1
      AND (@OrganizationId IS NULL OR stranka.OrganizationId = @OrganizationId)
  ) AS source
    ON target.CustomerId = source.CustomerId
  WHEN MATCHED THEN UPDATE SET
    CustomerKind = source.CustomerKind,
    WebEnabled   = CASE WHEN target.CustomerTypeCode IS NULL THEN 0 ELSE 1 END,
    UpdatedUtc   = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (CustomerId, CustomerKind, PackagingDiscountEnabled,
                                ValueDiscountEnabled, B2bPlusEnabled, WebEnabled, UpdatedUtc)
    VALUES (source.CustomerId, source.CustomerKind, 0, 0, 0, 0, SYSUTCDATETIME());
END;
');

EXEC(N'
/* Delovni seznam za cloveka: kaj je se treba odlociti pri strankah.
   PayerKindPredlog je izpeljan iz naziva in ni zapisan v profilu. */
CREATE OR ALTER VIEW pim.CustomerWebProfileToDecide
AS
SELECT
  stranka.OrganizationId,
  stranka.CustomerKey,
  stranka.Name,
  stranka.PayerCode,
  stranka.PriceListCode,
  profil.CustomerTypeCode,
  profil.PayerKind,
  CASE WHEN stranka.PayerCode IS NOT NULL AND LTRIM(RTRIM(stranka.PayerCode)) <> N''''
            AND stranka.PayerCode <> stranka.CustomerKey THEN 1 ELSE 0 END AS PlacnikJeNekdoDrug,
  CASE WHEN stranka.Name LIKE N''% PE %'' OR stranka.Name LIKE N''%, PE %''
            OR stranka.Name LIKE N''% PE'' OR stranka.Name LIKE N''%-PE %'' THEN N''PE'' END AS PayerKindPredlog
FROM b2b.Customer stranka
INNER JOIN pim.CustomerWebProfile profil ON profil.CustomerId = stranka.CustomerId
WHERE stranka.IsActive = 1
  AND (profil.CustomerTypeCode IS NULL
       OR (profil.PayerKind IS NULL
           AND stranka.PayerCode IS NOT NULL AND LTRIM(RTRIM(stranka.PayerCode)) <> N''''
           AND stranka.PayerCode <> stranka.CustomerKey));
');
