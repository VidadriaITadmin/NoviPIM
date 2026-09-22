/*
  174 — nabori iz mastrov opozarjajo, ne blokirajo.

  Uporabnik 2026-09-08 (po polnjenju 173): "lahko dodava atribute, katere se bo gledalo in spremljalo,
  da manjkajo — to bo treba pod validacijo dati in pa kot opozorilo, ne kot napako."

  173 je po pravilu zasedenosti 209 vrstic zapisala kot REQUIRED, kar je v spletnem profilu drevesa
  zahteva ERROR (147) in izdelek brez vrednosti ustavi na poti na splet. Odlocitev uporabnika je, da je
  nabor iz mastrov orodje za spremljanje manjkajocega: manjkajoci atribut je opozorilo (WARNING) na
  /kakovost in na kartici izdelka, izvoza ne ustavi. Zato gredo vse vrstice, ki jih je zapisal master
  (UpdatedBy = 'mastri 2026-09-08') in so se REQUIRED, na RECOMMENDED — skozi
  canon.SaveCategoryAttributeSet, ki hkrati spremeni zahtevo iz ERROR v WARNING.

  Raven "obvezen" ostane na voljo: kdor hoce, da kaksen atribut splet res blokira, ga na
  /nastavitve/nabori-atributov nastavi rocno; taka vrstica (drug UpdatedBy) tu ni dotaknjena in
  prezivi tudi ponovni zagon 173.
*/

SET XACT_ABORT ON;

DECLARE @Tree nvarchar(100), @Category nvarchar(200), @Attribute nvarchar(200), @Changed int = 0;
DECLARE required_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT CategoryTreeCode, CategoryCode, AttributeCode
  FROM canon.CategoryAttributeSet
  WHERE UpdatedBy = N'mastri 2026-09-08' AND IsActive = 1 AND Level = N'REQUIRED'
  ORDER BY CategoryTreeCode, CategoryCode, AttributeCode;
OPEN required_cursor;
FETCH NEXT FROM required_cursor INTO @Tree, @Category, @Attribute;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC canon.SaveCategoryAttributeSet @Tree, @Category, @Attribute, N'RECOMMENDED', N'mastri 2026-09-08', NULL;
  SET @Changed += 1;
  FETCH NEXT FROM required_cursor INTO @Tree, @Category, @Attribute;
END;
CLOSE required_cursor; DEALLOCATE required_cursor;
PRINT CONCAT(N'174: obvezni iz mastrov -> priporoceni: ', @Changed);
