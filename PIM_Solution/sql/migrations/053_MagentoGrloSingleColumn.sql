/*
  053 — stolpec 'Grlo ANG' se preimenuje v 'Grlo'.

  Zakaj: migracija 052 je ugasnila 'Grlo SLO', ker je vrednost grla koda (E14, GU10, G9)
  in je ni kaj prevajati. S tem je pripona 'ANG' izgubila pomen — locevala je od slovenske
  razlicice, ki je ni vec. Odlocitev uporabnika, 2026-08-21.

  Uvoz v Magento povezuje stolpce po imenu glave, zato je ime pogodba: 'Grlo' je tisto,
  kar bo treba povezati z Magentovim atributom.

  Skupaj z imenom se preimenuje kanonicna koda: 'Attr.Grlo ANG' -> 'Attr.Grlo'. Preslikave
  v map.FieldMapping za ta atribut se ni, zato ni kaj uskladiti; kdor jo bo pisal, naj cilja
  na ProductAttribute.Grlo.
*/

SET XACT_ABORT ON;

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

IF @ProductProfileId IS NULL
  THROW 52390, 'Profil MAGENTO_PRODUCTS ne obstaja; najprej mora tece migracija 045.', 1;

UPDATE out.ExportColumn
SET OutputColumnName = N'Grlo', CanonicalFieldCode = N'Attr.Grlo'
WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL054'
  AND OutputColumnName = N'Grlo ANG';

IF NOT EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL054'
    AND IsActive = 1 AND OutputColumnName = N'Grlo' AND CanonicalFieldCode = N'Attr.Grlo'
)
  THROW 52391, 'Stolpec 54 ni ostal aktiven z imenom Grlo.', 1;
