/*
  220 — Nowodvorski slike/dokumenti: protokol-relativni URL ("//pim.nowodvorski.com/...") dobi
        "https:" spredaj, drugace se v katalogu povezava ne odpre (Magento/urejevalniki
        pricakujejo popoln URL).

  Uporabnik 2026-09-17 je v katalog.csv opazil, da so v stolpcih "Glavna slika"/"Ostale slike"
  vsi Nowodvorski URL-ji brez sheme ("//pim.nowodvorski.com/media/files/10017.jpg"), medtem ko so
  Braytronovi ze polni ("https://cdn.braytron.center/..."). Prosil je: "se povsod kjer je
  //pim.nowodvorski.com je treba https: spredaj, ker drugace se ne bo link odprl talo pri slikah
  kot pri dokumentih" — torej isto velja za dokumente (Energijska nalepka, Navodila za montazo).

  Vzrok: NW_XML posilja pot brez sheme (XML vir sam), map.FieldMapping za `ProductMedia.Url` in za
  oba dokumentna atributa (`ProductDocument.Energijska nalepka`, `ProductDocument.Navodila za
  montazo`) pa nima bilo nobenega koraka v map.FieldTransform — vrednost gre v canon/pim
  nespremenjena (map.ApplyValueTransforms sploh ne obdela polja brez aktivnega koraka, glej pogoj
  EXISTS v #Scope). Braytron posilja ze poln URL po svoji, locenih preslikavah (BT_XML) — nanje
  ta migracija ne vpliva.

  Izmerjeno pred popravkom (DAVID\MSSQL19): canon.ProductMedia 26.726 / 34.607 protokol-relativnih,
  pim.ProductMedia 23.080 / 29.988, canon.ProductDocument 6.134 / 13.155; preostanek je ze
  absoluten (Braytron), 0 vrstic z drugo/mesano obliko.

  Popravek v treh delih (isti vzorec kot 216 za druge pretvorbe):
    1. Nov korak pretvorbe HTTPSPREFIX (map.ApplyValueTransforms, oznaka /* HttpsPrefix220 */):
       "//..." -> "https://...", karkoli drugega (ze absoluten URL) pusti pri miru — varno tudi,
       ce bi Nowodvorski nekoc zacel posiljati poln URL.
    2. map.FieldTransform: nov korak HTTPSPREFIX na vseh aktivnih NW_XML preslikavah v
       ProductMedia.Url in ProductDocument.* (12 preslikav, vse doslej brez koraka) — od
       naslednjega zajema naprej pride URL v canon/pim ze popravljen.
    3. Enkratni popravek obstojecih vrstic: canon.ProductMedia, pim.ProductMedia,
       canon.ProductDocument, kjer Url LIKE '//%'.

  Migracija je ponovljiva: vsak del preveri, ali je ze narejen. Migrator ne pozna GO (061), zato
  CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'map.ApplyValueTransforms') IS NULL THROW 52200, N'220: map.ApplyValueTransforms ne obstaja.', 1;

/* ======================================================================================
   1) Nova koda pretvorbe: dovoljene vrednosti
   ====================================================================================== */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_FieldTransform_Code' AND parent_object_id = OBJECT_ID(N'map.FieldTransform')
           AND definition NOT LIKE N'%HTTPSPREFIX%')
BEGIN
  ALTER TABLE map.FieldTransform DROP CONSTRAINT CK_FieldTransform_Code;
  ALTER TABLE map.FieldTransform ADD CONSTRAINT CK_FieldTransform_Code CHECK (TransformCode IN
    (N'TRIM', N'NUMBER', N'UNIT', N'PREFIX', N'STRIPPREFIX', N'BOOL', N'UPPER', N'LOWER', N'LOOKUP',
     N'BEFORE', N'AFTER', N'REQUIRE', N'WARRANTY', N'CAPITALIZE', N'HTTPSPREFIX'));
END;

/* ======================================================================================
   2) map.ApplyValueTransforms: nova veja HTTPSPREFIX
   ====================================================================================== */

DECLARE @transforms nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms'));
IF @transforms IS NULL THROW 52201, N'220: map.ApplyValueTransforms ne obstaja.', 1;
/* ziva definicija ima lahko samo LF, medtem ko ima literal @old spodaj v datoteki CRLF (znan
   autocrlf zaplet, glej 214) - normaliziraj obe strani na LF pred primerjavo. */
SET @transforms = REPLACE(@transforms, NCHAR(13), N'');

IF @transforms NOT LIKE N'%/* HttpsPrefix220 */%'
BEGIN
  DECLARE @old nvarchar(max) = N'        WHEN N''STRIPPREFIX'' THEN
          CASE
            WHEN LTRIM(value.Value) LIKE step.Argument + N''%''
              THEN NULLIF(LTRIM(RTRIM(SUBSTRING(LTRIM(value.Value), LEN(step.Argument) + 1, 400))), N'''')
            ELSE value.Value
          END';
  SET @old = REPLACE(@old, NCHAR(13), N'');
  DECLARE @new nvarchar(max) = @old + N'
        /* HttpsPrefix220 */
        WHEN N''HTTPSPREFIX'' THEN
          CASE WHEN value.Value LIKE N''//%'' THEN N''https:'' + value.Value ELSE value.Value END';
  IF CHARINDEX(@old, @transforms) = 0 OR CHARINDEX(@old, @transforms, CHARINDEX(@old, @transforms) + 1) <> 0
    THROW 52202, N'220: veja STRIPPREFIX v map.ApplyValueTransforms ni najdena natanko enkrat.', 1;
  SET @transforms = REPLACE(@transforms, @old, @new);
  SET @transforms = N'ALTER ' + SUBSTRING(@transforms, CHARINDEX(N'PROCEDURE', @transforms), 2147483647);
  EXEC sys.sp_executesql @transforms;
END;

/* ======================================================================================
   3) map.FieldTransform: korak HTTPSPREFIX na aktivnih NW_XML preslikavah slik/dokumentov
   ====================================================================================== */

INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument, IsActive)
SELECT mapping.FieldMappingId,
       ISNULL((SELECT MAX(step.StepOrder) FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId), 0) + 1,
       N'HTTPSPREFIX', NULL, 1
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.SourceCode = N'NW_XML' AND mapping.IsActive = 1
  AND (mapping.TargetFieldCode = N'ProductMedia.Url' OR mapping.TargetFieldCode LIKE N'ProductDocument.%')
  AND NOT EXISTS (SELECT 1 FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId AND step.TransformCode = N'HTTPSPREFIX');

/* ======================================================================================
   4) Obstojeci podatki: enkratni popravek ze zajetih URL-jev
   ====================================================================================== */

UPDATE canon.ProductMedia SET Url = N'https:' + Url WHERE Url LIKE N'//%';
UPDATE pim.ProductMedia SET Url = N'https:' + Url WHERE Url LIKE N'//%';
UPDATE canon.ProductDocument SET Url = N'https:' + Url WHERE Url LIKE N'//%';

/* --- Dokaz ------------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_FieldTransform_Code' AND parent_object_id = OBJECT_ID(N'map.FieldTransform') AND definition NOT LIKE N'%HTTPSPREFIX%')
  THROW 52203, N'220: koda HTTPSPREFIX ni dovoljena.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) NOT LIKE N'%/* HttpsPrefix220 */%'
  THROW 52204, N'220: map.ApplyValueTransforms nima veje HTTPSPREFIX.', 1;
IF (SELECT COUNT(*) FROM map.FieldTransform step
    JOIN map.FieldMapping mapping ON mapping.FieldMappingId = step.FieldMappingId
    JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
    WHERE connector.SourceCode = N'NW_XML' AND mapping.IsActive = 1 AND step.TransformCode = N'HTTPSPREFIX' AND step.IsActive = 1
      AND (mapping.TargetFieldCode = N'ProductMedia.Url' OR mapping.TargetFieldCode LIKE N'ProductDocument.%')) <> 12
  THROW 52205, N'220: pricakovanih 12 aktivnih NW_XML preslikav slik/dokumentov s korakom HTTPSPREFIX.', 1;
IF EXISTS (SELECT 1 FROM canon.ProductMedia WHERE Url LIKE N'//%')
   OR EXISTS (SELECT 1 FROM pim.ProductMedia WHERE Url LIKE N'//%')
   OR EXISTS (SELECT 1 FROM canon.ProductDocument WHERE Url LIKE N'//%')
  THROW 52206, N'220: se vedno obstajajo protokol-relativni URL-ji.', 1;
