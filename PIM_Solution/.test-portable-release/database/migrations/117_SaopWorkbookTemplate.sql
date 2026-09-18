/*
  116 — enotna Excelova predloga za artikle: isti stolpci za izvoz, uvoz v PIM in pošiljanje v SAOP.

  Zahteva uporabnika: »imamo v mislih, da mora biti enoten Excel, ki bo pasal povsod. Tako da
  boš lahko vse podatke urejal in s tem Excelom uvažal v PIM in pa v SAOP nove artikle in
  spremenjene.« Stari sistem je to imel (SaopSheetIo): ena predloga za POST in PATCH, stolpci
  pa so bili imena elementov SAOP.

  Predloga zato ni seznam, vpisan v kodo, ampak register out.SaopXmlField — isti register, ki
  ga uporablja odhodna vrsta. Če se register dopolni, se predloga dopolni sama.

  Dve bralni proceduri:

  1. intranet.GetSaopTemplateColumns — stolpci predloge: ime elementa SAOP (naslov stolpca),
     ključ polja v katalogu (od kod vrednost), oblika in ali je pri novem artiklu obvezen.
     Vključno z elementi brez ključa (ItemType, VATRateID): pri novem artiklu jih SAOP zahteva,
     PIM pa jih danes ne hrani — stolpec mora obstajati, da jih je mogoče vpisati.

  2. intranet.GetProductFieldValues — vrednosti teh polj za dane izdelke, v dolgi obliki
     (izdelek, ključ, vrednost). Bere canon.FieldValue, ki te ključe že pozna; merjeno
     121.814 vrednosti za 20.000 izdelkov v 37 ms. Pivot v stolpce naredi izvoz, ker vrstni
     red stolpcev določa register in ne poizvedba.

  Nobena procedura ničesar ne piše.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSaopTemplateColumns
  @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;
  SELECT field.SortOrder, field.ElementName, field.Section, field.FieldKey,
    field.ValueFormat, field.IsAddMandatory,
    /* Ali sme PIM to polje pisati nazaj v SAOP; drugo je v predlogi samo za nov artikel. */
    IsWritable = CONVERT(bit, CASE WHEN EXISTS
    (
      SELECT 1 FROM out.OwnershipPolicy AS ownership
      WHERE ownership.TargetKind = field.TargetKind AND ownership.FieldName = field.FieldKey
        AND ownership.Owner = N''PIM'' AND ownership.IsEnabled = 1
    ) THEN 1 ELSE 0 END)
  FROM out.SaopXmlField AS field
  WHERE field.TargetKind = @TargetKind AND field.IsEnabled = 1
  ORDER BY field.SortOrder;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductFieldValues
  @ProductIdsJson nvarchar(max),
  @TargetKind nvarchar(100) = N''SAOP_PRODUCT''
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  SELECT fieldValue.ProductId, fieldValue.FieldCode, fieldValue.Value
  FROM canon.FieldValue AS fieldValue
  INNER JOIN @Products AS product ON product.ProductId = fieldValue.ProductId
  WHERE EXISTS
  (
    SELECT 1 FROM out.SaopXmlField AS field
    WHERE field.TargetKind = @TargetKind AND field.IsEnabled = 1 AND field.FieldKey = fieldValue.FieldCode
  );
END;');
