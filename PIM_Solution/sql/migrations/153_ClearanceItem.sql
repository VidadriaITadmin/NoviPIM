-- 153: Zacasna tabela za odprodajo/zalogo odprodaje (fizicne trgovine, rocni uvoz iz Excela).
-- Stran (svetila/videlektro) se polni iz zivega izvoza katalog.csv, ne iz notranje kategorije,
-- ker preslikava NW->videlektro v tem sistemu se ne obstaja (glej pim.ProductCategory.WebSite).
-- To je namenoma ravna tabela brez FK na canon.Warehouse: lokacije v odprodaji se niso preverjene.

IF OBJECT_ID(N'pim.ClearanceItem', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ClearanceItem
  (
    ClearanceItemId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    Vir nvarchar(100) NOT NULL,
    Sifra nvarchar(100) NOT NULL,
    Ean nvarchar(100) NULL,
    NaSvetila bit NOT NULL CONSTRAINT DF_ClearanceItem_NaSvetila DEFAULT (0),
    NaVidelektro bit NOT NULL CONSTRAINT DF_ClearanceItem_NaVidelektro DEFAULT (0),
    Kolicina decimal(19,4) NULL,
    RednaCena decimal(19,4) NULL,
    PopustOdstotek decimal(5,2) NULL,
    OdprodajnaCena decimal(19,4) NULL,
    IzvornaDatoteka nvarchar(260) NULL,
    ImportiranoUtc datetime2(3) NOT NULL CONSTRAINT DF_ClearanceItem_ImportiranoUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ClearanceItem PRIMARY KEY CLUSTERED (ClearanceItemId),
    CONSTRAINT UQ_ClearanceItem_ProductVir UNIQUE (ProductId, Vir),
    CONSTRAINT FK_ClearanceItem_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'pim.ClearanceItem', N'U') IS NULL
  THROW 51500, N'153: pim.ClearanceItem manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'NaVidelektro')
  THROW 51501, N'153: pim.ClearanceItem.NaVidelektro manjka.', 1;
