/*
  129 — kartica stranke: vrsta stranke, poslovne enote in tranziti, zaznamki, zgodovina.

  Zahteve uporabnika 2026-08-28 (poglavje »Poslovanje / Stranke«):

    H1 »Treba je dodati da so kupci, kupci in dobavitelj, dobavitelj, proizvajalec«
    H3 »Treba je videti osnovne podatke stranke tako da daj zavihke pri strankah in
        poimenuj Splosni podatki«
    H4 »Potem dodaj komercialne podatke kamor gredo vsa ta pravila (B2B spletne nastavitve,
        skupine popusta, tip stranke, vrsta stranke, popust na polno pakiranje, vrednostni
        rabat, b2b+, popust NW, posebni popusti za stranke)«
    H5 »Nov zavihek poslovne enote in tranziti — ... omogociti da dodajajo poslovne enote iz
        seznama ali na novo in tranzite«
    H6 »Dodati je treba zaznamek kjer bo samo polje z besedilom ki bo sluzil kot opombe
        uporabnikov in fino bi bilo, da vidijo uporabniki opombe med sabo«
    H8 »dodati je treba zgodovino spremembe te stranke«

  Kaj ta migracija naredi in cesa namenoma ne:

  1. **Vrsta stranke dobi proizvajalca.** Omejitev na pim.CustomerWebProfile je poznala
     CUSTOMER, SUPPLIER in BOTH. Uporabnik je nastel se proizvajalca, zato je dodan
     MANUFACTURER. Stara omejitev se odstrani in postavi znova — drugace ni mogoce.

  2. **Poslovne enote in tranziti dobijo svojo tabelo** pim.CustomerBranch. Zakaj svoja
     tabela in ne stolpec: ena stranka jih ima vec, vsaka pa ima svojo vrsto (PE ali tranzit).
     Enota je lahko obstojeca stranka iz sifranta (BranchCustomerId) ali rocno vpisana
     (BranchCode + BranchName) — uporabnik je izrecno zahteval oboje. Razlika PE/tranzit je
     poslovno nosilna: po `docs/pravila/Magento_Pravila_Cene_Popusti_Postnine 1.docx` §4.10
     PE podeduje osnovne skupinske popuste od placnika, tranzit pa jih nima.

  3. **Zaznamki dobijo svojo tabelo** pim.CustomerNote: prosto besedilo z avtorjem in casom.
     Vrstice se ne posodabljajo in ne brisejo — zaznamek je zapis, kdo je kdaj kaj zapisal;
     popravljanje tujega zapisa bi to unicilo. Zato ni stolpca UpdatedUtc.

  4. **Zgodovina ne dobi nove tabele.** b2b.AuditLog ze obstaja in vanj pise
     SaveCustomerWebProfile; kartica ga samo prebere. Nova tabela bi bila drugi vir resnice.

  5. **Komercialna pravila ne dobijo novih tabel.** Vsa nasteta ze obstajajo:
     pim.CustomerWebProfile (B2B spletne nastavitve, tip in vrsta stranke, popust na polno
     pakiranje, vrednostni rabat, B2B+), b2b.CustomerItemGroupDiscount (skupine popustov,
     med njimi NW), pim.CustomerValueDiscountTier (vrednostni pragovi) in
     b2b.CustomerPackagingDiscountOverride (posebni popusti za stranko). Kartica jih zbere
     v en bralni klic; podvajanje bi jih razslo.

  Procedure berejo, razen dveh, ki pisata zaznamek in poslovno enoto — obe sta izrecna
  zahteva uporabnika in obe pisata samo v tabeli iz te migracije.

  Migracija je ponovljiva: vsak korak preveri, ali je ze narejen.
*/

SET XACT_ABORT ON;

/* --- 1) Vrsta stranke pozna se proizvajalca ------------------------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_CustomerWebProfile_Kind')
  ALTER TABLE pim.CustomerWebProfile DROP CONSTRAINT CK_CustomerWebProfile_Kind;

/* Omejitev je bila ustvarjena brez imena, zato jo poiscemo po nadrejeni tabeli in besedilu. */
DECLARE @unnamed sysname = (
  SELECT TOP (1) name FROM sys.check_constraints
  WHERE parent_object_id = OBJECT_ID(N'pim.CustomerWebProfile')
    AND definition LIKE N'%CustomerKind%');
IF @unnamed IS NOT NULL
BEGIN
  /* EXEC ne sprejme sestavljenega izraza, samo spremenljivko. */
  DECLARE @drop nvarchar(400) = N'ALTER TABLE pim.CustomerWebProfile DROP CONSTRAINT ' + QUOTENAME(@unnamed) + N';';
  EXEC sp_executesql @drop;
END;

ALTER TABLE pim.CustomerWebProfile WITH CHECK ADD CONSTRAINT CK_CustomerWebProfile_Kind
  CHECK (CustomerKind IS NULL OR CustomerKind IN (N'CUSTOMER', N'SUPPLIER', N'BOTH', N'MANUFACTURER'));

/* --- 2) Poslovne enote in tranziti ------------------------------------------------------ */

IF OBJECT_ID(N'pim.CustomerBranch', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerBranch
  (
    CustomerBranchId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    /* Stranka, ki enoto ima — v pravilih placnik. */
    CustomerId bigint NOT NULL,
    /* Enota iz sifranta strank; NULL pomeni rocno vpisano enoto. */
    BranchCustomerId bigint NULL,
    BranchCode nvarchar(200) NULL,
    BranchName nvarchar(600) NULL,
    /* PE podeduje osnovne skupinske popuste od placnika, tranzit jih nima (pravila §4.10). */
    BranchKind nvarchar(20) NOT NULL,
    Note nvarchar(1000) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CustomerBranch_IsActive DEFAULT (1),
    CreatedBy nvarchar(200) NOT NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerBranch_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerBranch_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_CustomerBranch PRIMARY KEY CLUSTERED (CustomerBranchId),
    CONSTRAINT FK_CustomerBranch_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT FK_CustomerBranch_BranchCustomer FOREIGN KEY (BranchCustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT CK_CustomerBranch_Kind CHECK (BranchKind IN (N'PE', N'TRANZIT')),
    /* Enota mora biti bodisi iz sifranta bodisi rocno vpisana; prazna vrstica ni enota. */
    CONSTRAINT CK_CustomerBranch_Identity CHECK (BranchCustomerId IS NOT NULL OR NULLIF(LTRIM(RTRIM(BranchName)), N'') IS NOT NULL)
  );

  CREATE INDEX IX_CustomerBranch_Customer ON pim.CustomerBranch (OrganizationId, CustomerId, IsActive);
END;

/* Ista enota iz sifranta se pri isti stranki ne sme pojaviti dvakrat. Rocno vpisane enote
   filtrirani indeks ne zajame, ker jih loci ime in ne kljuc. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_CustomerBranch_Known' AND object_id = OBJECT_ID(N'pim.CustomerBranch'))
  CREATE UNIQUE INDEX UQ_CustomerBranch_Known ON pim.CustomerBranch (CustomerId, BranchCustomerId)
    WHERE BranchCustomerId IS NOT NULL;

/* --- 3) Zaznamki ------------------------------------------------------------------------ */

IF OBJECT_ID(N'pim.CustomerNote', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerNote
  (
    CustomerNoteId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    CustomerId bigint NOT NULL,
    Body nvarchar(4000) NOT NULL,
    CreatedBy nvarchar(200) NOT NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerNote_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_CustomerNote PRIMARY KEY CLUSTERED (CustomerNoteId),
    CONSTRAINT FK_CustomerNote_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT CK_CustomerNote_Body CHECK (NULLIF(LTRIM(RTRIM(Body)), N'') IS NOT NULL)
  );

  CREATE INDEX IX_CustomerNote_Customer ON pim.CustomerNote (OrganizationId, CustomerId, CreatedUtc DESC);
END;

/* --- 4) Kartica stranke v enem bralnem klicu -------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCustomerCard
  @OrganizationId int,
  @CustomerId bigint
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @CustomerKey nvarchar(200) = (
    SELECT customer.CustomerKey FROM b2b.Customer AS customer
    WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerId = @CustomerId);

  /* 1 — splosni podatki: kar je prislo iz SAOP, in profil, ki je last PIM. */
  SELECT customer.CustomerId, customer.CustomerKey, customer.Name,
    customer.PayerCode, customer.PayerName, customer.PriceListCode, customer.DiscountPriceListCode,
    customer.Address, customer.Street, customer.HouseNumber, customer.City, customer.PostalCode,
    customer.Country, customer.TaxNumber, customer.RegistrationNumber, customer.ActivityCode,
    customer.SubjectToVat, customer.PaymentDays, customer.RebatePercent, customer.IsActive,
    customer.CustomerType AS SourceCustomerType, customer.LegalForm, customer.IsDefaulter,
    customer.UpfrontPayment, customer.LanguageId, customer.CurrencyCode, customer.UpdatedUtc,
    profileValue.CustomerTypeCode, profileValue.CustomerKind, profileValue.PayerKind,
    PackagingDiscountEnabled = COALESCE(profileValue.PackagingDiscountEnabled, CONVERT(bit, 0)),
    ValueDiscountEnabled = COALESCE(profileValue.ValueDiscountEnabled, CONVERT(bit, 0)),
    B2bPlusEnabled = COALESCE(profileValue.B2bPlusEnabled, CONVERT(bit, 0)),
    profileValue.B2bPlusValidFrom, profileValue.B2bPlusValidTo,
    WebEnabled = COALESCE(profileValue.WebEnabled, CONVERT(bit, 0)),
    MagentoGroupKey = magentoGroup.MagentoGroupKey,
    CustomerTypeName = typeCatalog.Name
  FROM b2b.Customer AS customer
  LEFT JOIN pim.CustomerWebProfile AS profileValue ON profileValue.CustomerId = customer.CustomerId
  LEFT JOIN pim.CustomerTypeCatalog AS typeCatalog ON typeCatalog.CustomerTypeCode = profileValue.CustomerTypeCode
  LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup
    ON magentoGroup.CustomerTypeCode = profileValue.CustomerTypeCode AND magentoGroup.IsActive = 1
  WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerId = @CustomerId;

  /* 2 — skupine popustov po skupini artiklov. Nosilna vez je skupina strank (pravila §4.1),
         zato se berejo po Magento skupini stranke, ne po sifri stranke. */
  SELECT discount.ItemGroupCode, discount.DiscountPercent, discount.MinQuantity,
    discount.ValidFrom, discount.ValidTo, discount.CustomerGroupCode
  FROM b2b.CustomerItemGroupDiscount AS discount
  WHERE discount.OrganizationId = @OrganizationId
    AND discount.CustomerGroupCode IN
    (
      SELECT magentoGroup.MagentoGroupKey
      FROM pim.CustomerWebProfile AS profileValue
      INNER JOIN pim.CustomerTypeMagentoGroup AS magentoGroup
        ON magentoGroup.CustomerTypeCode = profileValue.CustomerTypeCode AND magentoGroup.IsActive = 1
      WHERE profileValue.CustomerId = @CustomerId
    )
  ORDER BY discount.ItemGroupCode;

  /* 3 — vrednostni pragovi stranke. */
  SELECT tier.TierNumber, tier.ThresholdGrossExVat, tier.PercentValue, tier.IsActive
  FROM pim.CustomerValueDiscountTier AS tier
  WHERE tier.CustomerId = @CustomerId
  ORDER BY tier.TierNumber;

  /* 4 — posebni popusti za stranko na posameznem izdelku. */
  SELECT overrideValue.OverrideId, overrideValue.DiscountCode, overrideValue.ValidFrom,
    overrideValue.ValidTo, overrideValue.IsActive,
    ItemID = product.ItemID, ProductName = product.ItemID
  FROM b2b.CustomerPackagingDiscountOverride AS overrideValue
  LEFT JOIN pim.Product AS product ON product.PimProductId = overrideValue.PimProductId
  WHERE overrideValue.CustomerId = @CustomerId
  ORDER BY overrideValue.OverrideId DESC;

  /* 5 — poslovne enote in tranziti. */
  SELECT branch.CustomerBranchId, branch.BranchKind, branch.IsActive, branch.Note,
    branch.CreatedBy, branch.CreatedUtc,
    BranchCustomerId = branch.BranchCustomerId,
    BranchCode = COALESCE(branchCustomer.CustomerKey, branch.BranchCode),
    BranchName = COALESCE(branchCustomer.Name, branch.BranchName),
    FromCatalog = CONVERT(bit, CASE WHEN branch.BranchCustomerId IS NULL THEN 0 ELSE 1 END)
  FROM pim.CustomerBranch AS branch
  LEFT JOIN b2b.Customer AS branchCustomer ON branchCustomer.CustomerId = branch.BranchCustomerId
  WHERE branch.OrganizationId = @OrganizationId AND branch.CustomerId = @CustomerId
  ORDER BY branch.BranchKind, COALESCE(branchCustomer.Name, branch.BranchName);

  /* 6 — zaznamki, najnovejsi zgoraj. */
  SELECT note.CustomerNoteId, note.Body, note.CreatedBy, note.CreatedUtc
  FROM pim.CustomerNote AS note
  WHERE note.OrganizationId = @OrganizationId AND note.CustomerId = @CustomerId
  ORDER BY note.CreatedUtc DESC, note.CustomerNoteId DESC;

  /* 7 — zgodovina sprememb iz obstojece revizijske sledi; nove tabele ni. */
  SELECT auditValue.AuditLogId, auditValue.EntityType, auditValue.ActionCode,
    auditValue.OldValueJson, auditValue.NewValueJson, auditValue.ChangedBy, auditValue.ChangedUtc
  FROM b2b.AuditLog AS auditValue
  WHERE auditValue.OrganizationId = @OrganizationId
    AND auditValue.EntityKey IN (CONVERT(nvarchar(200), @CustomerId), @CustomerKey)
  ORDER BY auditValue.ChangedUtc DESC, auditValue.AuditLogId DESC;
END;');

/* --- 5) Pisanje zaznamka --------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.AddCustomerNote
  @OrganizationId int,
  @CustomerId bigint,
  @Body nvarchar(4000),
  @CreatedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @Body = NULLIF(LTRIM(RTRIM(@Body)), N'''');
  IF @Body IS NULL THROW 51001, N''Zaznamek brez besedila ni zaznamek.'', 1;

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 51002, N''Stranka v tem podjetju ne obstaja.'', 1;

  INSERT pim.CustomerNote (OrganizationId, CustomerId, Body, CreatedBy)
  VALUES (@OrganizationId, @CustomerId, @Body, @CreatedBy);

  SELECT CustomerNoteId = SCOPE_IDENTITY();
END;');

/* --- 6) Pisanje poslovne enote oziroma tranzita ------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.SaveCustomerBranch
  @OrganizationId int,
  @CustomerId bigint,
  @BranchKind nvarchar(20),
  @BranchCustomerId bigint = NULL,
  @BranchCode nvarchar(200) = NULL,
  @BranchName nvarchar(600) = NULL,
  @Note nvarchar(1000) = NULL,
  @CreatedBy nvarchar(200) = N''neznan''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @BranchKind = UPPER(LTRIM(RTRIM(@BranchKind)));
  IF @BranchKind NOT IN (N''PE'', N''TRANZIT'') THROW 51003, N''Enota je lahko PE ali TRANZIT.'', 1;

  SET @BranchCode = NULLIF(LTRIM(RTRIM(@BranchCode)), N'''');
  SET @BranchName = NULLIF(LTRIM(RTRIM(@BranchName)), N'''');
  SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'''');

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 51002, N''Stranka v tem podjetju ne obstaja.'', 1;

  IF @BranchCustomerId IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @BranchCustomerId AND OrganizationId = @OrganizationId)
    THROW 51004, N''Izbrana enota ni stranka tega podjetja.'', 1;

  IF @BranchCustomerId IS NULL AND @BranchName IS NULL
    THROW 51005, N''Rocno vpisana enota mora imeti ime.'', 1;

  IF @BranchCustomerId IS NOT NULL AND @BranchCustomerId = @CustomerId
    THROW 51006, N''Stranka ne more biti svoja poslovna enota.'', 1;

  /* Ponovno dodajanje iste enote iz sifranta ni napaka, ampak popravek njene vrste. */
  IF @BranchCustomerId IS NOT NULL
     AND EXISTS (SELECT 1 FROM pim.CustomerBranch WHERE CustomerId = @CustomerId AND BranchCustomerId = @BranchCustomerId)
  BEGIN
    UPDATE pim.CustomerBranch
    SET BranchKind = @BranchKind, Note = @Note, IsActive = 1, UpdatedUtc = SYSUTCDATETIME()
    WHERE CustomerId = @CustomerId AND BranchCustomerId = @BranchCustomerId;

    SELECT CustomerBranchId FROM pim.CustomerBranch
    WHERE CustomerId = @CustomerId AND BranchCustomerId = @BranchCustomerId;
    RETURN;
  END;

  INSERT pim.CustomerBranch (OrganizationId, CustomerId, BranchCustomerId, BranchCode, BranchName, BranchKind, Note, CreatedBy)
  VALUES (@OrganizationId, @CustomerId, @BranchCustomerId, @BranchCode, @BranchName, @BranchKind, @Note, @CreatedBy);

  SELECT CustomerBranchId = SCOPE_IDENTITY();
END;');
