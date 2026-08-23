/*
  071 — zaloga po izdelku dobi indeks.

  Najdeno pri padcu PIM.F3.Integration: ciscenje testa je preseglo 300 sekund. Ni bilo pocasno
  brisanje zgodovine, ampak ena sama vrstica —

    DELETE FROM stock.Position WHERE MatchedProductId IN (...)

  ker stock.Position nima indeksa po MatchedProductId. Tabela ima 245.696 vrstic, zato je vsako
  vprasanje "kaj je na zalogi za ta izdelek" pregled cele tabele.

  To ni le testna nadloga: po isti poti gleda intranet zalogo na izkaznici izdelka in po isti
  poti se izdelek brise. Indeks je majhen (ena vrednost na pozicijo) in ga potrebujeta oba.

  Vkljuceni stolpci so tisti, ki jih bralec potrebuje takoj za tem — kolicina in posnetek —
  da poizvedba ne rabi nazaj v tabelo.
*/

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.Position') AND name = N'IX_stock_Position_MatchedProduct')
BEGIN
  CREATE INDEX IX_stock_Position_MatchedProduct
    ON stock.Position(MatchedProductId)
    INCLUDE (Quantity, SnapshotId, AvailabilityDate)
    WHERE MatchedProductId IS NOT NULL;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.Position') AND name = N'IX_stock_Position_MatchedProduct')
  THROW 52711, 'Indeks zaloge po izdelku ni nastal.', 1;
