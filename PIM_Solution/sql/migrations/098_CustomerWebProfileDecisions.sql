/*
  098 — popravek 097: vrsta stranke (kupec / trgovec / oboje) je odlocitev cloveka, ne izpeljava.

  V 097 sem CustomerKind polnil iz pravne oblike (P/F). To je bilo napacno v dveh pogledih:
  pravna oblika pove, ali je stranka pravna ali fizicna oseba, ne pa ali je kupec ali dobavitelj;
  in CHECK CK_CustomerWebProfile_Kind dovoljuje CUSTOMER / SUPPLIER / BOTH, torej natanko
  "kupec, trgovec ali oboje" iz odlocitve uporabnika. MERGE je zato pravilno padel.

  Ali je vrsto mogoce izpeljati iz SAOP? Preverjeno: CustomerType ima stiri vrednosti in nobena
  ni samoumevna —

      O  11.514   primer: MARCHIOL d.o.o., PE LJUBLJANA
      K      47   primer: "Koncni kupec po starem"
      D       4   primer: ACB, niceshops GmbH
      S       1   primer: RODIC MATIC

  Crke bi se dalo prebrati kot Oboje / Kupec / Dobavitelj, a "O" nosi 99,5 % strank vseh vrst,
  zato bi bila taka izpeljava ugibanje s 11.514 posledicami. Uporabnik je povedal, da vrsto
  doloci sam; postopek je torej ne postavi.

  Kaj se spremeni: pim.PromoteCustomerWebProfile ustvari vrstico in NE postavi CustomerKind.
  pim.CustomerWebProfileToDecide dobi kontekst iz SAOP (crka vrste, pravna oblika) in vkljuci
  tudi stranke brez vrste — da je na enem seznamu vse, kar clovek se mora odlociti.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE pim.PromoteCustomerWebProfile
  @OrganizationId int = NULL
AS
BEGIN
  /*
    Vrstica profila za vsako aktivno stranko. Postopek je namenoma prazen: vse troje, kar profil
    nosi — vrsta stranke, tip stranke in PE/tranzit — je odlocitev cloveka in je SAOP ne ve.
    Zato se ta postopek odlocitev nikoli ne dotakne in ga je varno pognati vsako noc.

    WebEnabled ostane 0, dokler stranka nima tipa. To ni previdnost, ampak pravilo iz dokumenta
    o pravilih: skupina strank je nosilna vez za vse cene in popuste, zato stranka brez tipa v
    izvoz ne sme. out.ExportB2bCustomersCsv ze filtrira po WebEnabled = 1.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  MERGE pim.CustomerWebProfile AS target
  USING
  (
    SELECT stranka.CustomerId
    FROM b2b.Customer stranka
    WHERE stranka.IsActive = 1
      AND (@OrganizationId IS NULL OR stranka.OrganizationId = @OrganizationId)
  ) AS source
    ON target.CustomerId = source.CustomerId
  WHEN MATCHED THEN UPDATE SET
    WebEnabled = CASE WHEN target.CustomerTypeCode IS NULL THEN 0 ELSE 1 END,
    UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (CustomerId, PackagingDiscountEnabled, ValueDiscountEnabled,
                                B2bPlusEnabled, WebEnabled, UpdatedUtc)
    VALUES (source.CustomerId, 0, 0, 0, 0, SYSUTCDATETIME());
END;
');

EXEC(N'
/* Delovni seznam za cloveka: kaj je se treba odlociti pri strankah. Predlogi so predlogi in se
   v profil ne zapisejo, dokler jih clovek ne potrdi. */
CREATE OR ALTER VIEW pim.CustomerWebProfileToDecide
AS
SELECT
  stranka.OrganizationId,
  stranka.CustomerKey,
  stranka.Name,
  stranka.PayerCode,
  stranka.PriceListCode,
  stranka.CustomerType AS SaopVrsta,
  stranka.LegalForm    AS SaopPravnaOblika,
  profil.CustomerKind,
  profil.CustomerTypeCode,
  profil.PayerKind,
  CASE WHEN stranka.PayerCode IS NOT NULL AND LTRIM(RTRIM(stranka.PayerCode)) <> N''''
            AND stranka.PayerCode <> stranka.CustomerKey THEN 1 ELSE 0 END AS PlacnikJeNekdoDrug,
  CASE WHEN stranka.Name LIKE N''% PE %'' OR stranka.Name LIKE N''%, PE %''
            OR stranka.Name LIKE N''% PE'' OR stranka.Name LIKE N''%-PE %'' THEN N''PE'' END AS PayerKindPredlog
FROM b2b.Customer stranka
INNER JOIN pim.CustomerWebProfile profil ON profil.CustomerId = stranka.CustomerId
WHERE stranka.IsActive = 1
  AND (profil.CustomerKind IS NULL
       OR profil.CustomerTypeCode IS NULL
       OR (profil.PayerKind IS NULL
           AND stranka.PayerCode IS NOT NULL AND LTRIM(RTRIM(stranka.PayerCode)) <> N''''
           AND stranka.PayerCode <> stranka.CustomerKey));
');
