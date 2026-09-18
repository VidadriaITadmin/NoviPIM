/*
  202 — stranke.csv: v izvoz gre vsaka aktivna stranka; oznaka Splet in tip nista pogoj.

  Uporabnik 2026-09-15: »stranke ne bodo mela kljukice splet, samo aktivnost, ce imajo, drugace
  ne. Ta splet kljukica se tice samo artiklov.«

  Migracija 201 je stranko v stranke.csv spustila samo, ce je bila aktivna, imela oznako Splet
  (pim.CustomerWebProfile.WebEnabled) in tip (CustomerTypeCode). Uporabnik je oznako za stranke
  odpravil: pri strankah steje samo aktivnost iz SAOP (b2b.Customer.IsActive), kljukice spletisc
  so stvar artiklov. Tip stranke ostane podatek na kartici (doloca Magento skupino v datoteki),
  ni pa vec pogoj za izvoz — stranka brez tipa gre ven s prazno skupino.

  Pravilo po tej migraciji: stranka je v stranke.csv, ce je b2b.Customer.IsActive = 1.
  @OnlyPublished = 0 (predogled v intranetu) se vedno vrne vse stranke.

  Sprememba je enaka kot v 194 in 201: definicija out.GetExportRows se prebere iz baze in v njej
  se zamenja en izraz (dvakrat: stevec in stran). Pred zamenjavo se presteje; ce definicija ni
  taka, kot jo je pustila 201, migracija pade.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition IS NULL THROW 52211, N'202: out.GetExportRows ne obstaja.', 1;

IF @Definition NOT LIKE N'%customer.IsActive = 1 /* 202 */%'
BEGIN
  DECLARE @CustomerOld nvarchar(400) = N'(@OnlyPublished = 0 OR (profile.WebEnabled = 1 AND customer.IsActive = 1 AND profile.CustomerTypeCode IS NOT NULL /* 201 */))';
  DECLARE @CustomerNew nvarchar(400) = N'(@OnlyPublished = 0 OR customer.IsActive = 1 /* 202 */)';

  IF (LEN(@Definition) - LEN(REPLACE(@Definition, @CustomerOld, N''))) / LEN(@CustomerOld) <> 2
    THROW 52212, N'202: out.GetExportRows nima pricakovanih dveh filtrov strank iz 201.', 1;

  SET @Definition = REPLACE(@Definition, @CustomerOld, @CustomerNew);

  DECLARE @HeaderEnd int = CHARINDEX(N'PROCEDURE', @Definition);
  IF @HeaderEnd = 0 OR LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
       LEFT(@Definition, @HeaderEnd - 1), N'CREATE', N''), N'OR ALTER', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))) <> N''
    THROW 52213, N'202: glava out.GetExportRows ni CREATE [OR ALTER] PROCEDURE.', 1;
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, @HeaderEnd, 2147483647);

  EXEC sys.sp_executesql @Definition;
END;

/* --- dokaz ------------------------------------------------------------------------------- */

SET @Definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition NOT LIKE N'%customer.IsActive = 1 /* 202 */%'
  THROW 52214, N'202: out.GetExportRows ne izbira strank po aktivnosti.', 1;
IF @Definition LIKE N'%profile.WebEnabled%'
  THROW 52215, N'202: out.GetExportRows se vedno pogojuje stranke z oznako Splet.', 1;
IF @Definition NOT LIKE N'%ProductWebShop /* 201 */%' OR @Definition NOT LIKE N'%ProductHold /* 194 */%'
  THROW 52216, N'202: pravili za artikle iz 194/201 sta izginili iz out.GetExportRows.', 1;

DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
DECLARE @ProbeCustomerProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_CUSTOMERS' AND IsActive = 1);
DECLARE @ProbeTotal int;
IF @ProbeOrganizationId IS NOT NULL AND @ProbeCustomerProfileId IS NOT NULL
BEGIN
  EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProbeCustomerProfileId,
    @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
  IF @ProbeTotal <> (SELECT COUNT(*) FROM b2b.Customer AS customer
                     INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
                     WHERE customer.OrganizationId = @ProbeOrganizationId AND customer.IsActive = 1)
    THROW 52217, N'202: stevilo strank v izvozu ni enako stevilu aktivnih strank s profilom.', 1;
END;
