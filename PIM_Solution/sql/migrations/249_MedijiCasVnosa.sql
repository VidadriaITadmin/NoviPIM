/*
  249 - Mediji dobijo cas vnosa: canon.ProductMedia.CreatedUtc in canon.ProductDocument.CreatedUtc.

  Uporabnik 2026-09-22 (stran Mediji): "dodaj razvrscanje po casu". Tabeli medijev casa nista
  imeli, zato stran ni mogla povedati, kaj je novo: 82 slik z vipelektro.si, uvozenih iz Excela
  isti dan, so se izgubile med ~48.000 zapisi.

  Kaj naredi:
    1. Stolpec CreatedUtc (datetime2(3), NULL, privzeto SYSUTCDATETIME()) v obeh tabelah. Nove
       vrstice ga dobijo same - vsi pisci (map.ProcessRawInbox, map.ProcessDocumentInbox,
       pim.SaveProductMediaBulk) vstavljajo z nastetimi stolpci, zato jih ne spreminjamo.
       pim.SaveProductMediaBulk obstojece vrstice posodobi na mestu, cas vnosa zato ostane.
       NULL pomeni "dodano pred zacetkom belezenja", ne "danes".
    2. Enkratna polnitev slik iz pim.ProductFieldHistory (sprozilec TR_ProductMedia_FieldHistory
       belezi vsak vnos od 2026-08-20). Past: 2026-09-17 je migracija 220 prepisala 26.725
       naslovov NA MESTU (OldValue -> NewValue). Zadnji dogodek za tak naslov je prepis, ne vnos,
       zato polnitev sledi verigi OldValue nazaj do dogodka z OldValue IS NULL (pravi vnos). Brez
       tega bi 26.725 slik "nastalo" 17. 9. Ce veriga pred vnosom poci (naslov je obstajal pred
       belezenjem), ostane NULL.
    3. Enkratna polnitev dokumentov. canon.ProductDocument sprozilca zgodovine nima:
       a) dokument iz Excela (pim.SaveProductMediaBulk) ima vnos v pim.ProductFieldHistory
          (FieldKey 'ProductDocument.Url') - ta je natancen in ima prednost;
       b) sicer je cas vnosa prvi uvoz (raw.Inbox.ProcessedUtc), v katerem je ta naslov prisel za
          isto podjetje in isto vlogo (map.ExtractedValue, TargetFieldCode 'ProductDocument.<vloga>')
          - map.ProcessDocumentInbox dokument vstavi prav ob tej obdelavi. Naslov se primerja brez
          sheme, ker je 220 tudi dokumentom dodala https:. Preverjeno 2026-09-22: ujemanje za vseh
          13.163 dokumentov.

  Cesa NE naredi: sprozilca in piscev ne spreminja; indeksa ne doda - stran Mediji bere unijo obeh
  tabel in razvrsca izracunan nabor, indeks na eni tabeli tu ne pomaga.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Stolpca ------------------------------------------------------------------------------ */
IF COL_LENGTH(N'canon.ProductMedia', N'CreatedUtc') IS NULL
  ALTER TABLE canon.ProductMedia ADD CreatedUtc datetime2(3) NULL
    CONSTRAINT DF_CanonProductMedia_CreatedUtc DEFAULT (SYSUTCDATETIME());

IF COL_LENGTH(N'canon.ProductDocument', N'CreatedUtc') IS NULL
  ALTER TABLE canon.ProductDocument ADD CreatedUtc datetime2(3) NULL
    CONSTRAINT DF_ProductDocument_CreatedUtc DEFAULT (SYSUTCDATETIME());

/* Stolpec je v tej paketni datoteki nov, zato ga sme brati samo dinamicni SQL (migrator izvede
   datoteko kot en ukaz, brez GO). */

/* --- 2) Slike: veriga zgodovine nazaj do pravega vnosa ------------------------------------- */
EXEC(N'
CREATE TABLE #pot
(
  ProductMediaId bigint NOT NULL PRIMARY KEY,
  OrganizationId int NOT NULL,
  ProductId bigint NOT NULL,
  Url nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
  BeforeChangeId bigint NULL,
  CreatedUtc datetime2(3) NULL,
  Done bit NOT NULL DEFAULT (0)
);

INSERT #pot (ProductMediaId, OrganizationId, ProductId, Url)
SELECT media.ProductMediaId, product.OrganizationId, media.ProductId, CONVERT(nvarchar(400), media.Url)
FROM canon.ProductMedia AS media
INNER JOIN canon.Product AS product ON product.ProductId = media.ProductId
WHERE media.CreatedUtc IS NULL;

/* Vsak korak vzame zadnji dogodek, ki je dal ta naslov. Vnos (OldValue IS NULL) konca verigo s
   pravim casom; prepis (OldValue IS NOT NULL) nadaljuje s prejsnjim naslovom pred tem dogodkom. */
DECLARE @Korak int = 0;
WHILE @Korak < 20 AND EXISTS (SELECT 1 FROM #pot WHERE Done = 0)
BEGIN
  SET @Korak += 1;
  UPDATE pot SET
    Done = CASE WHEN dogodek.ChangeId IS NULL OR dogodek.OldValue IS NULL THEN 1 ELSE 0 END,
    CreatedUtc = CASE WHEN dogodek.ChangeId IS NOT NULL AND dogodek.OldValue IS NULL THEN dogodek.ChangedAtUtc END,
    Url = COALESCE(dogodek.OldValue, pot.Url),
    BeforeChangeId = dogodek.ChangeId
  FROM #pot AS pot
  OUTER APPLY
  (
    SELECT TOP (1) history.ChangeId, history.OldValue, history.ChangedAtUtc
    FROM pim.ProductFieldHistory AS history
    WHERE history.OrganizationId = pot.OrganizationId
      AND history.ProductId = pot.ProductId
      AND history.FieldKey = N''ProductMedia.Url''
      AND history.NewValue = pot.Url
      AND (pot.BeforeChangeId IS NULL OR history.ChangeId < pot.BeforeChangeId)
    ORDER BY history.ChangeId DESC
  ) AS dogodek
  WHERE pot.Done = 0;
END;

UPDATE media SET CreatedUtc = pot.CreatedUtc
FROM canon.ProductMedia AS media
INNER JOIN #pot AS pot ON pot.ProductMediaId = media.ProductMediaId
WHERE pot.CreatedUtc IS NOT NULL AND media.CreatedUtc IS NULL;

DECLARE @Slike int = (SELECT COUNT(*) FROM #pot WHERE CreatedUtc IS NOT NULL);
DECLARE @SlikeBrez int = (SELECT COUNT(*) FROM #pot WHERE CreatedUtc IS NULL);
PRINT CONCAT(N''249: slike s casom vnosa '', @Slike, N'', brez (pred belezenjem) '', @SlikeBrez, N''.'');
DROP TABLE #pot;
');

/* --- 3) Dokumenti: Excel iz zgodovine, sicer prvi uvoz s tem naslovom ----------------------- */
EXEC(N'
UPDATE document SET CreatedUtc = zgodovina.ChangedAtUtc
FROM canon.ProductDocument AS document
INNER JOIN canon.Product AS product ON product.ProductId = document.ProductId
CROSS APPLY
(
  SELECT ChangedAtUtc = MAX(history.ChangedAtUtc)
  FROM pim.ProductFieldHistory AS history
  WHERE history.OrganizationId = product.OrganizationId
    AND history.ProductId = document.ProductId
    AND history.FieldKey = N''ProductDocument.Url''
    AND history.OldValue IS NULL
    AND history.NewValue = LEFT(document.Url, 400)
) AS zgodovina
WHERE document.CreatedUtc IS NULL AND zgodovina.ChangedAtUtc IS NOT NULL;

CREATE TABLE #vir
(
  OrganizationId int NOT NULL,
  Role nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
  UrlKey nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL,
  FirstUtc datetime2(3) NULL
);

INSERT #vir (OrganizationId, Role, UrlKey, FirstUtc)
SELECT inbox.OrganizationId, SUBSTRING(value.TargetFieldCode, 17, 400), kljuc.UrlKey,
  MIN(COALESCE(inbox.ProcessedUtc, value.ExtractedUtc))
FROM map.ExtractedValue AS value
INNER JOIN raw.Inbox AS inbox ON inbox.InboxId = value.InboxId
CROSS APPLY (SELECT U = LTRIM(RTRIM(CONVERT(nvarchar(2000), value.Value)))) AS naslov
CROSS APPLY
(
  SELECT UrlKey = CONVERT(nvarchar(2000), CASE
    WHEN naslov.U LIKE N''https://%'' THEN SUBSTRING(naslov.U, 7, 2000)
    WHEN naslov.U LIKE N''http://%'' THEN SUBSTRING(naslov.U, 6, 2000)
    WHEN naslov.U LIKE N''www.%'' THEN N''//'' + naslov.U
    ELSE naslov.U END)
) AS kljuc
WHERE value.TargetFieldCode LIKE N''ProductDocument.%'' AND naslov.U <> N''''
GROUP BY inbox.OrganizationId, SUBSTRING(value.TargetFieldCode, 17, 400), kljuc.UrlKey;

UPDATE document SET CreatedUtc = vir.FirstUtc
FROM canon.ProductDocument AS document
INNER JOIN canon.Product AS product ON product.ProductId = document.ProductId
CROSS APPLY
(
  SELECT UrlKey = CONVERT(nvarchar(2000), CASE
    WHEN document.Url LIKE N''https://%'' THEN SUBSTRING(document.Url, 7, 2000)
    WHEN document.Url LIKE N''http://%'' THEN SUBSTRING(document.Url, 6, 2000)
    WHEN document.Url LIKE N''www.%'' THEN N''//'' + document.Url
    ELSE document.Url END)
) AS kljuc
INNER JOIN #vir AS vir
  ON vir.OrganizationId = product.OrganizationId AND vir.Role = document.Role AND vir.UrlKey = kljuc.UrlKey
WHERE document.CreatedUtc IS NULL AND vir.FirstUtc IS NOT NULL;

DROP TABLE #vir;

DECLARE @Dokumenti int = (SELECT COUNT(*) FROM canon.ProductDocument WHERE CreatedUtc IS NOT NULL);
DECLARE @DokumentiBrez int = (SELECT COUNT(*) FROM canon.ProductDocument WHERE CreatedUtc IS NULL);
PRINT CONCAT(N''249: dokumenti s casom vnosa '', @Dokumenti, N'', brez '', @DokumentiBrez, N''.'');
');
