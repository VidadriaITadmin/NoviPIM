/*
  079 — zgodovina sprememb dobi indeks po svežnju.

  Najdeno pri padcu PIM.F5.ValueTransformTests (341 s namesto nekaj sekund). Poizvedba, ki je
  padla, ni bila testna posebnost, ampak vzorec, ki ga uporablja vec testov in tudi intranet:

    ... WHERE NOT EXISTS (SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId = ...)

  pim.ProductFieldHistory ima 2.061.854 vrstic in nobenega indeksa po ChangeBatchId — obstajata
  po polju in po izdelku. Vsako vprasanje "ali ta svezenj se ima zgodovino" je bilo zato pregled
  dveh milijonov vrstic.

  Indeks je ozek (ena vrednost na vrstico) in ga potrebujeta oba: ciscenje testov in prikaz
  zgodovine po svezenj v intranetu.
*/

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_Batch')
BEGIN
  CREATE INDEX IX_PimProductFieldHistory_Batch
    ON pim.ProductFieldHistory(ChangeBatchId)
    INCLUDE (ProductId, ChangedAtUtc);
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_Batch')
  THROW 52791, 'Indeks zgodovine po svezenj ni nastal.', 1;
