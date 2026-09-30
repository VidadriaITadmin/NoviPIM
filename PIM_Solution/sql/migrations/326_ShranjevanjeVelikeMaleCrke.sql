/*
  326 — Shranjevanje atributov in besedil upošteva tudi spremembo samo velike/male črke — naloga #115.

  Najdeno pri preverjanju 323 (2026-09-30): sprožilca zgodovine že ločita velike/male črke, a kartica
  izdelka spremembe »max 25 W« -> »Max 25 W« sploh ne zapiše. Shranjevalne procedure imajo v MERGE
    WHEN MATCHED AND ISNULL(target.Value, N'') <> source.Value THEN UPDATE ...
  v kolaciji baze (SQL_Latin1_General_CP1_CI_AS = NE loči velikih in malih črk), zato vrstice ne
  posodobijo, sprožilec pa ne dobi ničesar. Gumb je pokazal (1), v bazi pa je ostala stara vrednost.

  Kaj naredi 326 (ena transakcija; če katerakoli kontrola pade, se nič ne spremeni):
    1. V ŽIVI definiciji petih shranjevalnih procedur zamenja samo pogoj primerjave v MERGE: obe strani
       dobita COLLATE Latin1_General_BIN2 (loči velike/male črke in naglase; presledki na koncu se še
       vedno ne štejejo kot sprememba). Procedure:
         pim.SaveProductAttributes      (kartica izdelka, atributi)
         pim.SaveProductTexts           (kartica izdelka, besedila)
         pim.SaveProductAttributesBulk  (delovni list / množično)
         pim.SaveProductTextsBulk       (delovni list / množično)
         pim.SaveProductErpFieldsBulk   (delovni list, besedila in atributi iz SAOP stolpcev — 2 MERGE)
    2. V pim.SaveProductAttributes in pim.SaveProductTexts enako popravi preverjanje sočasne spremembe
       (»expected«): če je nekdo drug medtem spremenil samo veliko/malo črko, je to zdaj spor, ne tiho
       prepisovanje.
    Sidra morajo biti v vsaki proceduri natanko tolikokrat, kot je pričakovano; sicer 326 ustavi
    (drift). Ponovni zagon ne naredi nič (oznaka /* 326 */).

  Kaj NE naredi: map.ProcessRawInbox (zajem dobaviteljev) in out.RecordExportPublication (sled objav)
  ostaneta, kot sta. Razveljavitev (pim.UndoProductField/UndoProductBatch) atributov in besedil ne
  podpira (samo WebPublish/IsActive), zato tam ni kaj popraviti.

  Vpliv: sprememba samo velike/male črke se zdaj zapiše v canon.ProductAttribute/ProductText, v
  pim.ProductFieldHistory (sprožilci iz 323) in sproži validacijo izdelka; ob naslednjem izvozu gre v
  katalog.csv. Pri SAOP poljih (SaveProductErpFieldsBulk) gre sprememba v vrsto za SAOP kot vsaka druga
  ročna sprememba (nič samodejno). Objekti: zgornjih 5 procedur (ALTER na živi definiciji).
  Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53260, N'326: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

DECLARE @MergeOld nvarchar(400) = N'WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN';
DECLARE @MergeNew nvarchar(400) = N'WHEN MATCHED AND ISNULL(target.Value, N'''') COLLATE Latin1_General_BIN2 <> source.Value COLLATE Latin1_General_BIN2 /* 326 */ THEN';
DECLARE @ExpOld nvarchar(400) = N'AND ISNULL(current_.Value, N'''') <> ISNULL(change.Expected, N'''');';
DECLARE @ExpNew nvarchar(400) = N'AND ISNULL(current_.Value, N'''') COLLATE Latin1_General_BIN2 <> ISNULL(change.Expected, N'''') COLLATE Latin1_General_BIN2 /* 326 */;';
DECLARE @Marker nvarchar(20) = N'/* 326 */';

DECLARE @Procs TABLE (Name sysname NOT NULL, MergeCount int NOT NULL, ExpCount int NOT NULL);
INSERT @Procs (Name, MergeCount, ExpCount) VALUES
  (N'pim.SaveProductAttributes', 1, 1),
  (N'pim.SaveProductTexts', 1, 1),
  (N'pim.SaveProductAttributesBulk', 1, 0),
  (N'pim.SaveProductTextsBulk', 1, 0),
  (N'pim.SaveProductErpFieldsBulk', 2, 0);

IF EXISTS (SELECT 1 FROM @Procs WHERE OBJECT_ID(Name, N'P') IS NULL)
  THROW 53261, N'326: manjka katera od shranjevalnih procedur (SaveProductAttributes/Texts/…Bulk/ErpFieldsBulk).', 1;

BEGIN TRANSACTION;

DECLARE @Name sysname, @MergeCount int, @ExpCount int, @Def nvarchar(max), @Found int, @Pos int, @Msg nvarchar(400);
DECLARE procs CURSOR LOCAL FAST_FORWARD FOR SELECT Name, MergeCount, ExpCount FROM @Procs;
OPEN procs;
FETCH NEXT FROM procs INTO @Name, @MergeCount, @ExpCount;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Def = OBJECT_DEFINITION(OBJECT_ID(@Name));
  IF CHARINDEX(@Marker, @Def) = 0
  BEGIN
    SET @Found = (LEN(@Def) - LEN(REPLACE(@Def, @MergeOld, N''))) / LEN(@MergeOld);
    IF @Found <> @MergeCount
    BEGIN
      SET @Msg = CONCAT(N'326: v ', @Name, N' pogoj MERGE najden ', @Found, N'x, pričakovano ', @MergeCount, N'x — živa definicija se razlikuje.');
      THROW 53262, @Msg, 1;
    END;
    SET @Found = (LEN(@Def) - LEN(REPLACE(@Def, @ExpOld, N''))) / LEN(@ExpOld);
    IF @Found <> @ExpCount
    BEGIN
      SET @Msg = CONCAT(N'326: v ', @Name, N' preverjanje »expected« najdeno ', @Found, N'x, pričakovano ', @ExpCount, N'x — živa definicija se razlikuje.');
      THROW 53263, @Msg, 1;
    END;
    SET @Def = REPLACE(REPLACE(@Def, @MergeOld, @MergeNew), @ExpOld, @ExpNew);
    SET @Pos = CHARINDEX(N'CREATE', @Def);
    IF @Pos = 0 OR CHARINDEX(N'PROCEDURE', @Def) < @Pos THROW 53264, N'326: definicija procedure se ne začne s CREATE.', 1;
    SET @Def = STUFF(@Def, @Pos, 6, N'ALTER');
    EXEC (@Def);
    SET @Def = OBJECT_DEFINITION(OBJECT_ID(@Name));
    IF (LEN(@Def) - LEN(REPLACE(@Def, @MergeNew, N''))) / LEN(@MergeNew) <> @MergeCount
       OR (LEN(@Def) - LEN(REPLACE(@Def, @ExpNew, N''))) / LEN(@ExpNew) <> @ExpCount
       OR CHARINDEX(@MergeOld, @Def) > 0
    BEGIN
      SET @Msg = CONCAT(N'326: ', @Name, N' po spremembi nima pričakovane primerjave BIN2.');
      THROW 53265, @Msg, 1;
    END;
  END;
  FETCH NEXT FROM procs INTO @Name, @MergeCount, @ExpCount;
END;
CLOSE procs;
DEALLOCATE procs;

COMMIT TRANSACTION;
PRINT N'326: shranjevalne procedure atributov in besedil ločijo velike/male črke.';
