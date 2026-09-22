/*
  198 — MID prag in predlagane vrednosti MIN/MID/MAX za pravilo zaloge.

  Izhodisce: MIN_MAX_proces.docx (sestanek + Lukini zapiski). PIM naj iz prodajnih analitik
  IZRACUNA in PREDLAGA MIN/MID/MAX namesto rocnega vnosa, samo za artikle razreda A/B (ABC).
  Luka predlaga tretji prag MID, viden SAMO v PIM: "MAX, potem pa nek MID, ki bi bil viden samo
  v PIM, ter MIN, ki bi bil v sistemu". SAOP MID polja nima — potrjeno v
  docs/Povezave_virov_in_sistemov/SAOP_API_swagger_v2.json: ItemWarehouseData pozna samo
  MinimumStock/MaximumStock. MID zato ne more nikoli oditi v SAOP, ne glede na to, kaj se
  zgodi z MIN/MAX v prihodnje.

  Uporabnik je potrdil (2026-09-14): v tej fazi PIM ostaja samo predlog, brez pisanja nazaj v
  SAOP — 103_StockReadModel.sql to arhitekturno odlocitev ze izrecno dokumentira ("Zaloga
  ostaja izrecno samo bralna: PIM je nikoli ne pise nazaj v ERP"). Zato so nove
  SuggestedMinimumStock/SuggestedMidStock/SuggestedMaximumStock LOCENE od obstojecih
  MinimumStock/MaximumStock (076_CustomPropertiesAndStockPolicy.sql) — slednja ostajata "kar
  pride iz SAOP" (GetItemsStockData) in se s to migracijo ne spreminjata. Predlogi so izracun
  PIM, ki jih clovek rocno pregleda in po potrebi prenese v SAOP (UI za to pride v naslednji
  fazi, ko bo znana formula izracuna).

  Polja se registrirajo v pim.FieldOwnership (vzorec 028/034), da naslednja faza (shranjevalna
  pot + UI za potrditev predloga) lahko takoj gradi na obstojecem sledenju sprememb/undo.
  canon.TR_ProductStockPolicy_FieldHistory (sprozilec po vzoru TR_Product_FieldHistory, 028) se
  NAMENOMA ne dodaja se v tej migraciji: pride skupaj s shranjevalno potjo, ko bo ta obstajala —
  registrirano polje brez sprozilca preprosto se ne zapisuje v zgodovino, kar je varno stanje.
*/

SET XACT_ABORT ON;

/* --- 1) nova polja na canon.ProductStockPolicy -------------------------------- */

IF COL_LENGTH(N'canon.ProductStockPolicy', N'MidStock') IS NULL
  ALTER TABLE canon.ProductStockPolicy ADD
    MidStock decimal(19,4) NULL,
    SuggestedMinimumStock decimal(19,4) NULL,
    SuggestedMidStock decimal(19,4) NULL,
    SuggestedMaximumStock decimal(19,4) NULL,
    SuggestionCalculatedUtc datetime2(3) NULL,
    SuggestionMethod nvarchar(50) NULL;

/* --- 2) canon.ProductStockPolicy postane dovoljena lokacija v pim.FieldOwnership --- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'pim.FieldOwnership') AND name=N'CK_PimFieldOwnership_Location')
  ALTER TABLE pim.FieldOwnership DROP CONSTRAINT CK_PimFieldOwnership_Location;
ALTER TABLE pim.FieldOwnership WITH CHECK ADD CONSTRAINT CK_PimFieldOwnership_Location
  CHECK (CanonTable IN (N'canon.Product',N'canon.ProductCommercial',N'canon.ProductText',N'canon.ProductAttribute',N'canon.ProductMedia',N'canon.ProductStockPolicy'));

MERGE pim.FieldOwnership AS target
USING (VALUES
  (N'StockPolicy.MidStock', N'PIM', N'canon.ProductStockPolicy', N'MidStock'),
  (N'StockPolicy.SuggestedMinimumStock', N'PIM', N'canon.ProductStockPolicy', N'SuggestedMinimumStock'),
  (N'StockPolicy.SuggestedMidStock', N'PIM', N'canon.ProductStockPolicy', N'SuggestedMidStock'),
  (N'StockPolicy.SuggestedMaximumStock', N'PIM', N'canon.ProductStockPolicy', N'SuggestedMaximumStock')
) AS source(FieldKey, Owner, CanonTable, CanonColumn)
  ON target.FieldKey = source.FieldKey
WHEN MATCHED THEN UPDATE SET Owner=source.Owner, CanonTable=source.CanonTable, CanonColumn=source.CanonColumn, IsActive=1
WHEN NOT MATCHED THEN INSERT (FieldKey, Owner, CanonTable, CanonColumn)
  VALUES (source.FieldKey, source.Owner, source.CanonTable, source.CanonColumn);

/* --- 3) preverbe --------------------------------------------------------------- */

IF COL_LENGTH(N'canon.ProductStockPolicy', N'MidStock') IS NULL
  THROW 52900, N'198: canon.ProductStockPolicy.MidStock manjka.', 1;
IF COL_LENGTH(N'canon.ProductStockPolicy', N'SuggestedMinimumStock') IS NULL
  THROW 52901, N'198: canon.ProductStockPolicy.SuggestedMinimumStock manjka.', 1;
IF COL_LENGTH(N'canon.ProductStockPolicy', N'SuggestedMidStock') IS NULL
  THROW 52902, N'198: canon.ProductStockPolicy.SuggestedMidStock manjka.', 1;
IF COL_LENGTH(N'canon.ProductStockPolicy', N'SuggestedMaximumStock') IS NULL
  THROW 52903, N'198: canon.ProductStockPolicy.SuggestedMaximumStock manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'pim.FieldOwnership') AND name=N'CK_PimFieldOwnership_Location' AND definition LIKE N'%ProductStockPolicy%')
  THROW 52904, N'198: CK_PimFieldOwnership_Location ne dovoljuje canon.ProductStockPolicy.', 1;
IF (SELECT COUNT(*) FROM pim.FieldOwnership WHERE CanonTable=N'canon.ProductStockPolicy' AND IsActive=1) < 4
  THROW 52905, N'198: polja pravila zaloge niso registrirana v pim.FieldOwnership.', 1;
