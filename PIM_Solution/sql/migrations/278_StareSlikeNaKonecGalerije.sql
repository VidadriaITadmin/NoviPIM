/*
  278 — slike, ki jih dobavitelj ne pošilja več, gredo na konec galerije (ne brišejo se).

  2026-09-23, posel Katalog dobaviteljev (XML) na razvoju: stran Media za NW_XML je šla v karanteno
  pri vseh podjetjih z »Violation of UNIQUE KEY constraint 'UQ_CanonProductMedia_ProductRoleSort' …
  (194802, PRIMARY, 1)«. Nowodvorski je pri NW.4907 umaknil glavno sliko 4907.jpg; prva slika v XML je
  zdaj 4907-2.jpg (prej GALLERY/2). MERGE v map.ProcessRawInbox (korak 13) slike ujema po
  (ProductId, Url): 4907-2.jpg je postavil na PRIMARY/1, 4907.jpg pa pustil na PRIMARY/1 → dvojnik.
  Ker je cela stran ena transakcija, se ni posodobila nobena NW slika (org 2: 44 artiklov z
  umaknjeno glavno sliko je zadostovalo za 2.599 zavrnjenih).

  Uporabnik 2026-09-24: »popravi slike, stare premakni na konec galerije«. Slike, ki jih vir ne
  pošilja več, ostanejo (dobavitelj artikel lahko umakne, mi pa imamo še zalogo); načrt je arhiv
  slik na naš strežnik, do takrat se ne izgubi nobena.

  map.ProcessRawInbox, korak 13 (oznaka /* 278 */):
    - PRED MERGE: za artikle, ki jim ta stran prinaša vsaj eno sliko, se vse njihove obstoječe
      slike, ki jih na strani ni, umaknejo na SortOrder 100000+ (PRIMARY postane GALLERY, AMBIENT
      ostane AMBIENT). Tako MERGE prosto razporedi slike vira na 1..n.
    - PO MERGE: umaknjene slike dobijo zaporedje takoj za slikami vira (n+1, n+2 …) v prejšnjem
      vrstnem redu.
    Slike artiklov, ki jih stran sploh ne omenja, ostanejo nedotaknjene. Slike iz delovnega lista
    (245) pri artiklu z dobaviteljevimi slikami gredo prav tako za slike vira — kot doslej ob
    naslednjem zajemu, le brez padca.

  Telo procedure ostane iz 273; migracija zamenja samo dva kosa besedila (vzorec 261), zato je
  ponovljiva. Rocni korak: ne. Obstoječe strani v karanteni se ne ponovijo same — naslednji zajem
  NW_XML (posel Katalog dobaviteljev, 6 h) prinese novo stran; na razvoju sta bili 5449 in 5454
  ponovljeni rocno (docs/DATABASE.md).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox'));

IF CHARINDEX(N'/* 278 */', @definicija) = 0
BEGIN
  DECLARE @predMerge nvarchar(200) = N'MERGE canon.ProductMedia AS target';
  DECLARE @poMerge nvarchar(200) = N'VALUES(source.ProductId,source.Url,source.Role,source.SortOrder);';

  IF (LEN(@definicija) - LEN(REPLACE(@definicija, @predMerge, N''))) / LEN(@predMerge) <> 1
    THROW 52780, N'278: v map.ProcessRawInbox ni natanko enega MERGE canon.ProductMedia.', 1;
  IF (LEN(@definicija) - LEN(REPLACE(@definicija, @poMerge, N''))) / LEN(@poMerge) <> 1
    THROW 52781, N'278: v map.ProcessRawInbox ni natanko enega konca MERGE canon.ProductMedia.', 1;

  DECLARE @novoPred nvarchar(max) = N'/* 278 */
      /* Slike, ki jih vir ne pošilja več, se umaknejo z mest 1..n (sicer dvojnik na UQ_CanonProductMedia_ProductRoleSort). */
      DROP TABLE IF EXISTS #MediaVira278;
      SELECT DISTINCT record.ProductId, Url = CONVERT(nvarchar(2000), value.Value)
      INTO #MediaVira278
      FROM map.ExtractedValue value
      INNER JOIN #Record record ON record.RecordOrdinal=value.RecordOrdinal
      INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1
      WHERE value.InboxId=@InboxId AND record.RejectionReason IS NULL AND record.ProductId IS NOT NULL
        AND value.TargetFieldCode=''ProductMedia.Url'' AND value.Value IS NOT NULL;
      WITH umaknjene AS
      (
        SELECT media.Role, media.SortOrder,
          Mesto = ROW_NUMBER() OVER (PARTITION BY media.ProductId ORDER BY media.SortOrder, media.ProductMediaId)
        FROM canon.ProductMedia media
        WHERE EXISTS (SELECT 1 FROM #MediaVira278 vir WHERE vir.ProductId=media.ProductId)
          AND NOT EXISTS (SELECT 1 FROM #MediaVira278 vir WHERE vir.ProductId=media.ProductId AND vir.Url=media.Url)
      )
      UPDATE umaknjene SET Role=CASE WHEN Role=''PRIMARY'' THEN ''GALLERY'' ELSE Role END, SortOrder=100000+Mesto;
      ' + @predMerge;

  DECLARE @novoPo nvarchar(max) = @poMerge + N'
      /* 278: umaknjene slike na konec galerije, takoj za slikami vira, v prejšnjem vrstnem redu. */
      WITH umaknjene AS
      (
        SELECT media.SortOrder,
          Novo = vir.Stevilo + ROW_NUMBER() OVER (PARTITION BY media.ProductId ORDER BY media.SortOrder)
        FROM canon.ProductMedia media
        CROSS APPLY (SELECT COUNT(*) Stevilo FROM #MediaVira278 v WHERE v.ProductId=media.ProductId) vir
        WHERE media.SortOrder>100000 AND vir.Stevilo>0
      )
      UPDATE umaknjene SET SortOrder=Novo;
      DROP TABLE IF EXISTS #MediaVira278;';

  SET @definicija = REPLACE(@definicija, @predMerge, @novoPred);
  SET @definicija = REPLACE(@definicija, @poMerge, @novoPo);
  SET @definicija = STUFF(@definicija, CHARINDEX(N'CREATE', @definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC(@definicija);
END;

IF CHARINDEX(N'/* 278 */', OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox'))) = 0
  THROW 52782, N'278: map.ProcessRawInbox ni posodobljen.', 1;
