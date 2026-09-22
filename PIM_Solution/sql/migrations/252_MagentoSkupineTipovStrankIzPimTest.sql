/*
  252 - Magento skupina za vsak tip stranke in tip 12 strank Vidadrie: prenos iz PIM_test.

  Uporabnik 2026-09-22: »iz [PIM_test].[pim].[CustomerTypeCatalog] lahko preberes, katere tipe
  strank imamo, iz [PIM_test].[pim].[CustomerWebProfile] pa, katera stranka ima katero skupino.
  To preberi, naredi seznam in preslikaj v najino PIM bazo.«

  Stanje pred migracijo (lokalna baza, 2026-09-22):
    - pim.CustomerTypeMagentoGroup: MagentoGroupKey prazen pri vseh 18 tipih, zato je stolpec
      »Skupina (Magento)« v stranke.csv prazen pri vseh 3.988 strankah IQLighting. Po dokumentu
      Magento_Pravila_Cene_Popusti_Postnine §1/§4.1 je skupina nosilna vez vseh cen in popustov.
    - PIM_test.pim.CustomerTypeCatalog ima 18 tipov z MagentoGroupCode (b2b_instalater ...).
      Vsak se po imenu 1:1 ujema s tipom v pim.CustomerTypeCatalog (preslikava kod iz 212).
    - PIM_test.pim.CustomerWebProfile: 354 profilov, 352 s tipom. 340 dodelitev je v PIM ze
      enakih (212), 2 v PIM_test nimata tipa, v PIM ni nobene dodelitve, ki je PIM_test nima.
      Razlika je samo pri 12 strankah: v PIM_test INSTALATER_MAX (»Instalater max«,
      b2b_instalater_max), v PIM MAX_INSTALLER (»Max instalater«). 212 je 2026-09-15 izbrala
      MAX_INSTALLER, ker je bila stara koda videti dvoumna; PIM_test pa ima oba tipa loceno, vsak
      s svojo Magento skupino, MAX_INSTALATER pa nima nobena stranka. Uporabnik 2026-09-22:
      »Kot v PIM_test« - 12 strank gre na INSTALLER_MAX.

  Zastavic, pragov in NW popusta iz PIM_test profila (6 profilov, 4 v DEMO s testnimi
  vrednostmi) ta migracija ne prenese - uporabnik 2026-09-22: »samo tipe in skupine«.
  IsWebEnabled iz PIM_test (0 pri 4 neaktivnih tipih) PIM ne nosi; izvoz ga danes ne uporablja.

  Vrednosti so dobesedne (kot 212): PIM_test ni na vsakem strezniku, kamor gre migracija.
  Pisanje gre skozi b2b.SaveCustomerTypeMapping in b2b.SaveCustomerWebProfile, edini poti z
  revizijsko sledjo (b2b.AuditLog). Rocno ze vpisana Magento skupina se ne prepise.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Magento skupina po tipu ---------------------------------------------------------------- */
DECLARE @Groups TABLE (CustomerTypeCode nvarchar(60) NOT NULL PRIMARY KEY, MagentoGroupKey nvarchar(100) NOT NULL);
INSERT @Groups (CustomerTypeCode, MagentoGroupKey) VALUES
  (N'INSTALLER', N'b2b_instalater'),
  (N'INSTALLER_MAX', N'b2b_instalater_max'),
  (N'INSTALLER_BRANCH', N'b2b_instalater_pe'),
  (N'INSTALLER_TRANSIT', N'b2b_instalater_tranzit'),
  (N'PUBLIC_SECTOR', N'b2b_javni_sektor'),
  (N'END_B2B', N'b2b_koncni_b2b'),
  (N'END_B2B_BRANCH', N'b2b_koncni_b2b_pe'),
  (N'MAX_INSTALLER', N'b2b_max_instalater'),
  (N'CARPENTER', N'b2b_mizar'),
  (N'RESALE', N'b2b_nadaljnja_prodaja'),
  (N'INACTIVE', N'b2b_neaktiven'),
  (N'DESIGNER', N'b2b_projektant'),
  (N'RESELLER', N'b2b_trgovec'),
  (N'RESELLER_INACTIVE', N'b2b_trgovec_neaktiven'),
  (N'RESELLER_BRANCH', N'b2b_trgovec_pe'),
  (N'RESELLER_BRANCH_INACTIVE', N'b2b_trgovec_pe_neaktiven'),
  (N'RESELLER_TRANSIT', N'b2b_trgovec_tranzit'),
  (N'RESELLER_TRANSIT_INACTIVE', N'b2b_trgovec_tranzit_neaktiven');

IF EXISTS (SELECT 1 FROM @Groups AS source
           WHERE NOT EXISTS (SELECT 1 FROM pim.CustomerTypeMagentoGroup AS target WHERE target.CustomerTypeCode = source.CustomerTypeCode))
  THROW 52521, N'252: tip stranke iz seznama nima vrstice v pim.CustomerTypeMagentoGroup.', 1;

DECLARE @OrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig WHERE IsActive = 1);
DECLARE @TypeCode nvarchar(60), @GroupKey nvarchar(100);
DECLARE groupCursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT source.CustomerTypeCode, source.MagentoGroupKey
  FROM @Groups AS source
  INNER JOIN pim.CustomerTypeMagentoGroup AS target ON target.CustomerTypeCode = source.CustomerTypeCode
  WHERE NULLIF(target.MagentoGroupKey, N'') IS NULL;
OPEN groupCursor;
FETCH NEXT FROM groupCursor INTO @TypeCode, @GroupKey;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC b2b.SaveCustomerTypeMapping @OrganizationId = @OrganizationId, @CustomerTypeCode = @TypeCode,
    @MagentoGroupKey = @GroupKey, @ChangedBy = N'migracija 252';
  FETCH NEXT FROM groupCursor INTO @TypeCode, @GroupKey;
END;
CLOSE groupCursor;
DEALLOCATE groupCursor;

/* --- 2) 12 strank Vidadrie: INSTALATER_MAX v PIM_test -> INSTALLER_MAX -------------------------- */
DECLARE @Customers TABLE (OrganizationId int NOT NULL, CustomerKey nvarchar(50) NOT NULL, PRIMARY KEY (OrganizationId, CustomerKey));
INSERT @Customers (OrganizationId, CustomerKey) VALUES
  (3, N'0000335'), (3, N'0000559'), (3, N'0000589'), (3, N'0000605'), (3, N'0000633'), (3, N'0001599'),
  (3, N'0001852'), (3, N'0002146'), (3, N'0002161'), (3, N'0002175'), (3, N'0002177'), (3, N'0002273');

/* Samo tam, kjer je se vedno tip iz 212 (MAX_INSTALLER): kasnejsa rocna odlocitev ostane. Procedura
   prepise vseh devet stolpcev profila, zato gredo ostali nespremenjeni nazaj (isto kot 212). */
DECLARE @CustomerOrganizationId int, @CustomerId bigint, @Kind nvarchar(20), @Packaging bit, @Value bit, @Plus bit,
  @PlusFrom date, @PlusTo date, @Web bit;
DECLARE customerCursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT customer.OrganizationId, customer.CustomerId, profile.CustomerKind, profile.PackagingDiscountEnabled,
    profile.ValueDiscountEnabled, profile.B2bPlusEnabled, profile.B2bPlusValidFrom, profile.B2bPlusValidTo, profile.WebEnabled
  FROM @Customers AS source
  INNER JOIN b2b.Customer AS customer ON customer.OrganizationId = source.OrganizationId AND customer.CustomerKey = source.CustomerKey
  INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
  WHERE profile.CustomerTypeCode = N'MAX_INSTALLER';
OPEN customerCursor;
FETCH NEXT FROM customerCursor INTO @CustomerOrganizationId, @CustomerId, @Kind, @Packaging, @Value, @Plus, @PlusFrom, @PlusTo, @Web;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC b2b.SaveCustomerWebProfile @OrganizationId = @CustomerOrganizationId, @CustomerId = @CustomerId,
    @CustomerTypeCode = N'INSTALLER_MAX', @CustomerKind = @Kind, @PackagingDiscountEnabled = @Packaging,
    @ValueDiscountEnabled = @Value, @B2bPlusEnabled = @Plus, @B2bPlusValidFrom = @PlusFrom, @B2bPlusValidTo = @PlusTo,
    @WebEnabled = @Web, @ChangedBy = N'migracija 252';
  FETCH NEXT FROM customerCursor INTO @CustomerOrganizationId, @CustomerId, @Kind, @Packaging, @Value, @Plus, @PlusFrom, @PlusTo, @Web;
END;
CLOSE customerCursor;
DEALLOCATE customerCursor;

/* --- Preverbe ---------------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM pim.CustomerTypeMagentoGroup WHERE NULLIF(MagentoGroupKey, N'') IS NULL)
  THROW 52522, N'252: vsak tip stranke mora imeti Magento skupino.', 1;
IF EXISTS (SELECT 1 FROM @Customers AS source
           INNER JOIN b2b.Customer AS customer ON customer.OrganizationId = source.OrganizationId AND customer.CustomerKey = source.CustomerKey
           INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
           WHERE profile.CustomerTypeCode = N'MAX_INSTALLER')
  THROW 52523, N'252: stranka iz PIM_test INSTALATER_MAX je se vedno MAX_INSTALLER.', 1;
