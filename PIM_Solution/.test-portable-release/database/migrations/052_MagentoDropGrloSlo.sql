/*
  052 — stolpec 'Grlo SLO' gre ven; grlo ima en sam stolpec.

  Zakaj: vrednost grla je koda (E14, GU10, G9), ne beseda — prevesti je ni kaj, zato sta
  bila stolpca 'Grlo ANG' in 'Grlo SLO' po vsebini ista. Odlocitev uporabnika, 2026-08-21.

  Zakaj je to poceni: uvoz v Magento povezuje stolpce po imenu glave (glej 050), zato
  premik zaporedja nikogar ne moti. Ostane 'Grlo ANG' (stolpec 54).

  Predloga ima po tej migraciji 213 aktivnih stolpcev.

  Enak vzorec kot v 050: zaporedje je enolicno tudi za ugasnjene vrstice, zato gre
  ugasnjeni stolpec najprej na prosto mesto zunaj obsega, ostali se strnejo, na koncu
  pa se ugasnjeni pripne za zadnjega aktivnega.
*/

SET XACT_ABORT ON;

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

IF @ProductProfileId IS NULL
  THROW 52380, 'Profil MAGENTO_PRODUCTS ne obstaja; najprej mora tece migracija 045.', 1;

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL055' AND IsActive = 1
)
BEGIN
  UPDATE out.ExportColumn SET IsActive = 0, SortOrder = 9055
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL055';

  UPDATE out.ExportColumn SET SortOrder = SortOrder - 1
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1 AND SortOrder > 55;

  UPDATE out.ExportColumn SET SortOrder = 214
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL055';
END;

/* --- preverba ------------------------------------------------------------- */

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND ColumnCode = N'COL054' AND IsActive = 0
)
  THROW 52381, 'Ugasnil se je napacen stolpec: Grlo ANG mora ostati aktiven.', 1;

IF
(
  SELECT COUNT(*) FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
) <> 213
  THROW 52382, 'Magento predloga nima 213 aktivnih stolpcev.', 1;

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn active
  WHERE active.ExportProfileId = @ProductProfileId AND active.IsActive = 1
    AND active.SortOrder NOT BETWEEN 1 AND 213
)
  THROW 52383, 'Zaporedje aktivnih stolpcev ni zvezno 1..213.', 1;
