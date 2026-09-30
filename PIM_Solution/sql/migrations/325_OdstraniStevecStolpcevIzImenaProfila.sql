/* 325_OdstraniStevecStolpcevIzImenaProfila — naloga #92 (razvijalec #92, 2026-09-30).

   Imeni profilov MAGENTO_PRODUCTS in MAGENTO_CUSTOMERS (migracija 045) sta vsebovali fiksno
   število stolpcev predloge, npr. »Magento - izdelki (predloga 215 stolpcev)«. Profil ima zdaj
   223 aktivnih stolpcev, zato je oznaka na /splet/izvoz zavajala. Število stolpcev stran zdaj
   prikaže živo (aktivni stolpci out.ExportColumn = glava CSV), iz imena pa ga odstranimo.

   Samo besedilo imena; iskanje profilov gre po ProfileCode. Ponovljivo (ime brez pripone ostane).
   Povratek: UPDATE out.ExportProfile SET Name = N'Magento - izdelki (predloga 215 stolpcev)'
             WHERE ProfileCode = N'MAGENTO_PRODUCTS'; (in N'Magento - stranke (predloga 19 stolpcev)'
             za MAGENTO_CUSTOMERS).
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

UPDATE profile
SET Name = RTRIM(LEFT(profile.Name, CHARINDEX(N' (predloga ', profile.Name) - 1)),
    UpdatedUtc = SYSUTCDATETIME()
FROM out.ExportProfile AS profile
WHERE profile.ProfileCode IN (N'MAGENTO_PRODUCTS', N'MAGENTO_CUSTOMERS')
  AND profile.Name LIKE N'% (predloga % stolpcev)'
  AND CHARINDEX(N' (predloga ', profile.Name) > 1;

COMMIT TRANSACTION;

SELECT ProfileCode, Name FROM out.ExportProfile
WHERE ProfileCode IN (N'MAGENTO_PRODUCTS', N'MAGENTO_CUSTOMERS');
