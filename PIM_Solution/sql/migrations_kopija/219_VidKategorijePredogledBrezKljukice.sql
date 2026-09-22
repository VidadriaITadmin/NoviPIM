/*
  219 — "Kategorije vid ANG/SLO" v katalogu polni tudi brez kljukice "videlektro" na kartici.

  Uporabnik 2026-09-17 je odprl svez katalog.csv (podjetje 2) in opozoril, da sta stolpca
  "Kategorije vid ANG/SLO" pri delu vrstic prazna: "kako to da so prazna? ta dva polja morata
  biti polna, tako kot sem ti rekel."

  Vzrok ni bila napaka preslikave 216/217. Migracija 213 je out.GetExportRows naredila tako, da
  je izdelek na posamezni spletni strani (in s tem njegova kategorija na tisti strani) v izvozu
  viden samo, ce ima na kartici (pim.ProductWebShop) prizgano kljukico za tisto stran (#Site,
  vrstici 133/139 v out.GetExportRows) — enaka kljukica, iz katere izhaja tudi stolpec "Spletne
  strani". 86 izdelkov (podjetje 2; kategorije npr. "Notranja svetila > Stropna svetila >
  Plafonjere", "Notranja svetila > Visece svetila", "Notranja svetila > Reflektorska svetila" ...)
  ima kljukico samo za svetila_si, ne za videlektro. Preverjeno v bazi (DAVID\MSSQL19, izdelek
  BA.BH15.01100, ProductId 140617): pim.ProductCategory ZA TE izdelke ze ima zrcaljeno vrstico na
  B2C/B2C_EN (216 jo je ustvarila, 217 ji je dodala predpono Razsvetljava/Lighting) — izvoz je le
  ne pokaze, ker izdelek (se) ni objavljen na videlektro.

  Uporabnikova odlocitev: stolpca naj bosta v katalogu vedno polna, kadar ima izdelek kategorijo
  svetila — informativno, BREZ vpliva na kljukico, na stolpec "Spletne strani" ali na dejansko
  objavo izdelka na videlektro.com (ponujene tri moznosti: prizgi kljukico vsem / pokazi samo v
  CSV brez objave / pusti kot je — izbral je drugo). Ce vrstice za Product.CategorySl/En ni
  (izdelek ni objavljen na videlektro), jo ta migracija dopolni iz Product.CategorySvetilaSl/En z
  isto predpono kot 217 ("Razsvetljava > " / "Lighting > "); ce vrstica ze obstaja (izdelek JE
  objavljen na videlektro), ostane taka, kot jo je izracunal obicajni potek (#Site/#Category).

  Vec kategorij na isti strani (STRING_AGG z "|", 213) je danes izmerjeno 0 primerov (2.176
  vrstic), koda pa jih vseeno pravilno loci in ponovno zdruzi (STRING_SPLIT/STRING_AGG), da
  predpona ne pokrije celega spojenega niza.

  Popravlja isto zivo definicijo kot 216/217, z oznako /* VidKategorijePreview219 */ takoj za
  koncem bloka 216 (po CREATE CLUSTERED INDEX IX_Value, da NOT EXISTS pod indeksom ni pocasen —
  izmerjeno v 216 na 2.176 izdelkih x ~100 poljih: brez indeksa > 5 minut, z indeksom nekaj sekund).
  Migrator ne pozna GO (061), zato ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'out.GetExportRows') IS NULL THROW 52190, N'219: out.GetExportRows ne obstaja.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* Catalog216 */%'
  THROW 52191, N'219: out.GetExportRows nima popravka 216 — migracije niso uporabljene po vrsti.', 1;

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));

IF @definition NOT LIKE N'%/* VidKategorijePreview219 */%'
BEGIN
  DECLARE @anchor nvarchar(max) = N'    WHERE NULLIF(value.Value,N'''') IS NOT NULL AND converted.Value<>value.Value;
  END;';
  DECLARE @at int = CHARINDEX(@anchor, @definition);
  IF @at = 0 OR CHARINDEX(@anchor, @definition, @at + 1) <> 0
    THROW 52192, N'219: konec bloka Catalog216 v out.GetExportRows ni najden natanko enkrat.', 1;

  DECLARE @block nvarchar(max) = N'
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN /* VidKategorijePreview219 */
    /* 219: "Kategorije vid ANG/SLO" v predogledu kataloga tudi, ce izdelek (se) nima kljukice
       "videlektro" na kartici — Razsvetljava/Lighting predpona kot 217, brez vpliva na objavo.
       Vec poti na isto stran (STRING_AGG z |, 213) locimo/zdruzimo, da predpona ne pokrije
       celega spojenega niza. */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT svetila.RowKey, N''Product.CategorySl'', prefixed.Value
    FROM #Value svetila
    CROSS APPLY (SELECT STRING_AGG(CONVERT(nvarchar(max), N''Razsvetljava > '' + part.value), N''|'')
                 FROM STRING_SPLIT(svetila.Value, N''|'') AS part) AS prefixed(Value)
    WHERE svetila.FieldCode = N''Product.CategorySvetilaSl'' AND NULLIF(svetila.Value, N'''') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM #Value vid WHERE vid.RowKey = svetila.RowKey AND vid.FieldCode = N''Product.CategorySl'');

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT svetila.RowKey, N''Product.CategoryEn'', prefixed.Value
    FROM #Value svetila
    CROSS APPLY (SELECT STRING_AGG(CONVERT(nvarchar(max), N''Lighting > '' + part.value), N''|'')
                 FROM STRING_SPLIT(svetila.Value, N''|'') AS part) AS prefixed(Value)
    WHERE svetila.FieldCode = N''Product.CategorySvetilaEn'' AND NULLIF(svetila.Value, N'''') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM #Value vid WHERE vid.RowKey = svetila.RowKey AND vid.FieldCode = N''Product.CategoryEn'');
  END;';

  SET @definition = STUFF(@definition, @at + LEN(@anchor), 0, @block);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- Dokaz ------------------------------------------------------------------------------- */
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* VidKategorijePreview219 */%'
  THROW 52193, N'219: popravek ni bil zapisan.', 1;
