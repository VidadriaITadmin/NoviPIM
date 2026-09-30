/*
  312 — preverjanje, ali se slike na naslovih (URL) res odprejo (naloga #9).

  Lastnik 2026-09-29 (odločitev #18, možnost B):
    - napaka validacije samo, če izdelek nima NOBENE delujoče slike; ena pokvarjena od več je opozorilo;
    - slika je pokvarjena šele po 2 neuspelih preverjanjih v razmiku vsaj 24 ur;
    - potrjeno pokvarjene slike se izpustijo iz katalog.csv; če je pokvarjena glavna, postane glavna prva delujoča.

  Kaj naredi:
    1. val.MediaUrlCheck — izid preverjanja na NASLOV (ne na vrstico slike): zajem XML (map.ProcessRawInbox)
       vrstice canon.ProductMedia zamenja, naslov pa ostane. Ključ je SHA2_256 obrezanega naslova (UrlHash).
       IsBroken je izračunan stolpec: FailureCount >= 2 in LastFailedUtc >= FirstFailedUtc + 24 h.
       NI_ODZIVA (429, 5xx, 401/403, časovna meja, brez povezave) števca ne poveča — strežniki dobaviteljev
       občasno ne odgovorijo in izdelki zaradi tega ne smejo pasti s spleta.
    2. val.GetMediaUrlsToCheck — vpiše nove naslove in vrne naslednji paket (novi, potrditev po 24 h,
       brez odziva po 6 h, ostali po 7 dneh). Kliče ga PIM.SourceFetchWorker --preveri-slike (posel MEDIA_URL_CHECK).
    3. val.RecordMediaUrlChecks — zapiše izide paketa (JSON) in vrne, koliko naslovov je na novo pokvarjenih.
    4. canon.FieldValue dobi dve izpeljani polji (oznaka PreverjanjeSlik312):
         ProductMedia.DelujocaSlika   — manjka samo, če ima izdelek slike in so VSE potrjeno pokvarjene;
         ProductMedia.VseSlikeDelujejo — manjka samo, če ima izdelek vsaj eno pokvarjeno IN vsaj eno delujočo.
       Validacija (val.RunValidation*) ju bere kot vsako drugo polje — en JOIN, brez zanke po izdelkih.
    5. val.FieldRequirement: v vsakem profilu, ki zahteva ProductMedia.Url, DelujocaSlika = ERROR in
       VseSlikeDelujejo = WARNING (danes WEB_svetila_si in WEB_videlektro).
    6. out.GetExportRows (zamenjava žive definicije, bloki 302-305 ostanejo): katalog.csv izpusti potrjeno
       pokvarjene slike; če je bila pokvarjena glavna, postane glavna prva preostala.
    7. intranet.GetMediaUrlChecks — seznam /mediji/napacni-naslovi (strežniško listanje, filtri, števci).
    8. ops.ScheduleProfile MEDIA_URL_CHECK (za ops.BeginRun). Posel v katalogu poslov je privzeto IZKLOPLJEN.

  Dokler posel ne teče, je val.MediaUrlCheck brez pokvarjenih naslovov in se ne spremeni nič (validacija,
  katalog.csv). Slik se ne briše: izpust iz katalog.csv je filter in je povraten (ob uspešnem preverjanju
  se števec ponastavi).

  Objekti: val.MediaUrlCheck, val.GetMediaUrlsToCheck, val.RecordMediaUrlChecks, intranet.GetMediaUrlChecks,
  canon.FieldValue, out.GetExportRows, podatki val.FieldRequirement in ops.ScheduleProfile. Ročni korak: ne.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'val.MediaUrlCheck', N'U') IS NULL
BEGIN
  CREATE TABLE val.MediaUrlCheck
  (
    UrlHash binary(32) NOT NULL CONSTRAINT PK_MediaUrlCheck PRIMARY KEY,
    Url nvarchar(4000) NOT NULL,
    Host nvarchar(255) NULL,
    FirstSeenUtc datetime2(0) NOT NULL CONSTRAINT DF_MediaUrlCheck_FirstSeen DEFAULT SYSUTCDATETIME(),
    LastCheckedUtc datetime2(0) NULL,
    LastOutcome nvarchar(20) NULL,
    LastHttpStatus int NULL,
    LastContentType nvarchar(200) NULL,
    LastErrorCode nvarchar(40) NULL,
    LastErrorText nvarchar(400) NULL,
    LastOkUtc datetime2(0) NULL,
    FirstFailedUtc datetime2(0) NULL,
    LastFailedUtc datetime2(0) NULL,
    FailureCount int NOT NULL CONSTRAINT DF_MediaUrlCheck_FailureCount DEFAULT 0,
    IsBroken AS CAST(CASE WHEN FailureCount >= 2 AND LastFailedUtc >= DATEADD(HOUR, 24, FirstFailedUtc) THEN 1 ELSE 0 END AS bit) PERSISTED,
    CONSTRAINT CK_MediaUrlCheck_Outcome CHECK (LastOutcome IS NULL OR LastOutcome IN (N'OK', N'NAPAKA', N'NI_ODZIVA'))
  );
  CREATE INDEX IX_MediaUrlCheck_Broken ON val.MediaUrlCheck (IsBroken) INCLUDE (FailureCount);
  CREATE INDEX IX_MediaUrlCheck_Due ON val.MediaUrlCheck (LastCheckedUtc) INCLUDE (LastOutcome, FailureCount);
END;
GO

CREATE OR ALTER PROCEDURE val.GetMediaUrlsToCheck
  @Limit int = 1500,
  @RecheckDays int = 7
AS
BEGIN
  /* 312: naslovi slik aktivnih izdelkov aktivnih podjetij; vsak naslov enkrat, ne vsaka vrstica slike. */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  DECLARE @now datetime2(0) = SYSUTCDATETIME();
  SET @Limit = CASE WHEN @Limit IS NULL OR @Limit < 1 THEN 1500 WHEN @Limit > 20000 THEN 20000 ELSE @Limit END;
  SET @RecheckDays = CASE WHEN @RecheckDays IS NULL OR @RecheckDays < 1 THEN 7 ELSE @RecheckDays END;

  CREATE TABLE #Current (UrlHash binary(32) NOT NULL PRIMARY KEY, Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Current (UrlHash, Url)
  SELECT address.UrlHash, MIN(address.Url)
  FROM
  (
    SELECT CAST(HASHBYTES('SHA2_256', LTRIM(RTRIM(media.Url))) AS binary(32)) AS UrlHash, LTRIM(RTRIM(media.Url)) AS Url
    FROM canon.ProductMedia AS media
    INNER JOIN canon.Product AS product ON product.ProductId = media.ProductId
    WHERE product.IsActive = 1
      AND product.OrganizationId IN (SELECT config.OrganizationId FROM dbo.OrganizationConfig AS config WHERE config.IsActive = 1)
      AND NULLIF(LTRIM(RTRIM(media.Url)), N'') IS NOT NULL
  ) AS address
  GROUP BY address.UrlHash;

  INSERT val.MediaUrlCheck (UrlHash, Url, Host)
  SELECT currentUrl.UrlHash, currentUrl.Url,
    CASE WHEN CHARINDEX(N'://', currentUrl.Url) > 0
      THEN LEFT(LOWER(SUBSTRING(currentUrl.Url, CHARINDEX(N'://', currentUrl.Url) + 3,
             CHARINDEX(N'/', currentUrl.Url + N'/', CHARINDEX(N'://', currentUrl.Url) + 3) - CHARINDEX(N'://', currentUrl.Url) - 3)), 255)
      ELSE NULL END
  FROM #Current AS currentUrl
  WHERE NOT EXISTS (SELECT 1 FROM val.MediaUrlCheck AS existing WHERE existing.UrlHash = currentUrl.UrlHash);

  SELECT TOP (@Limit) CONVERT(varchar(64), mediaCheck.UrlHash, 2) AS UrlHash, mediaCheck.Url
  FROM val.MediaUrlCheck AS mediaCheck
  INNER JOIN #Current AS currentUrl ON currentUrl.UrlHash = mediaCheck.UrlHash
  WHERE mediaCheck.LastCheckedUtc IS NULL
     OR (mediaCheck.FailureCount > 0 AND mediaCheck.IsBroken = 0 AND mediaCheck.LastCheckedUtc <= DATEADD(HOUR, -24, @now))
     OR (mediaCheck.LastOutcome = N'NI_ODZIVA' AND mediaCheck.LastCheckedUtc <= DATEADD(HOUR, -6, @now))
     OR mediaCheck.LastCheckedUtc <= DATEADD(DAY, -@RecheckDays, @now)
  ORDER BY
    CASE WHEN mediaCheck.LastCheckedUtc IS NULL THEN 0
         WHEN mediaCheck.FailureCount > 0 AND mediaCheck.IsBroken = 0 THEN 1
         WHEN mediaCheck.LastOutcome = N'NI_ODZIVA' THEN 2
         ELSE 3 END,
    mediaCheck.LastCheckedUtc, mediaCheck.UrlHash;
END;
GO

CREATE OR ALTER PROCEDURE val.RecordMediaUrlChecks
  @ResultsJson nvarchar(max)
AS
BEGIN
  /* 312: izidi paketa. OK ponastavi stevec, NAPAKA ga poveca, NI_ODZIVA ga pusti (ne steje kot pokvarjena). */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF ISJSON(@ResultsJson) <> 1 THROW 53121, N'312: izidi preverjanja niso veljaven JSON.', 1;
  DECLARE @now datetime2(0) = SYSUTCDATETIME();
  DECLARE @Changes TABLE (WasBroken bit NOT NULL, IsBroken bit NOT NULL);

  UPDATE mediaCheck
  SET LastCheckedUtc = @now,
      LastOutcome = result.Outcome,
      LastHttpStatus = result.HttpStatus,
      LastContentType = LEFT(result.ContentType, 200),
      LastErrorCode = LEFT(result.ErrorCode, 40),
      LastErrorText = LEFT(result.ErrorText, 400),
      Host = COALESCE(LEFT(result.Host, 255), mediaCheck.Host),
      LastOkUtc = CASE WHEN result.Outcome = N'OK' THEN @now ELSE mediaCheck.LastOkUtc END,
      FailureCount = CASE result.Outcome WHEN N'OK' THEN 0 WHEN N'NAPAKA' THEN mediaCheck.FailureCount + 1 ELSE mediaCheck.FailureCount END,
      FirstFailedUtc = CASE result.Outcome WHEN N'OK' THEN NULL WHEN N'NAPAKA' THEN ISNULL(mediaCheck.FirstFailedUtc, @now) ELSE mediaCheck.FirstFailedUtc END,
      LastFailedUtc = CASE result.Outcome WHEN N'OK' THEN NULL WHEN N'NAPAKA' THEN @now ELSE mediaCheck.LastFailedUtc END
  OUTPUT deleted.IsBroken, inserted.IsBroken INTO @Changes (WasBroken, IsBroken)
  FROM val.MediaUrlCheck AS mediaCheck
  INNER JOIN
  (
    SELECT TRY_CONVERT(binary(32), parsed.UrlHash, 2) AS UrlHash, parsed.Outcome, parsed.HttpStatus, parsed.ContentType,
      parsed.ErrorCode, parsed.ErrorText, parsed.Host
    FROM OPENJSON(@ResultsJson) WITH
    (
      UrlHash varchar(64) '$.h', Outcome nvarchar(20) '$.o', HttpStatus int '$.s', ContentType nvarchar(400) '$.t',
      ErrorCode nvarchar(80) '$.e', ErrorText nvarchar(800) '$.x', Host nvarchar(400) '$.host'
    ) AS parsed
    WHERE parsed.Outcome IN (N'OK', N'NAPAKA', N'NI_ODZIVA')
  ) AS result ON result.UrlHash = mediaCheck.UrlHash;

  SELECT
    Updated = COUNT(*),
    NewlyBroken = SUM(CASE WHEN WasBroken = 0 AND IsBroken = 1 THEN 1 ELSE 0 END),
    Recovered = SUM(CASE WHEN WasBroken = 1 AND IsBroken = 0 THEN 1 ELSE 0 END)
  FROM @Changes;
END;
GO

/* 4) canon.FieldValue: dve izpeljani polji za validacijo (zamenjava zive definicije, druge veje ostanejo). */
DECLARE @view nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'canon.FieldValue'));
IF @view IS NULL THROW 53122, N'312: canon.FieldValue manjka.', 1;
IF @view NOT LIKE N'%PreverjanjeSlik312%'
BEGIN
  DECLARE @anchor nvarchar(max) = N'UNION ALL SELECT ProductId, N''ProductMedia.Url'', NULLIF(Url, N'''') FROM canon.ProductMedia';
  IF CHARINDEX(@anchor, @view) = 0 THROW 53123, N'312: veja ProductMedia.Url v canon.FieldValue ni v pricakovani obliki.', 1;
  SET @view = REPLACE(@view, @anchor, @anchor + N'
/* PreverjanjeSlik312: DelujocaSlika manjka samo, ce ima izdelek slike in so vse potrjeno pokvarjene (val.MediaUrlCheck.IsBroken);
   VseSlikeDelujejo manjka samo, ce ima izdelek vsaj eno pokvarjeno in vsaj eno delujoco. Izdelek brez slik ima obe
   polji izpolnjeni - zanj velja ze ProductMedia.Url. */
UNION ALL SELECT product.ProductId, N''ProductMedia.DelujocaSlika'', N''1'' FROM canon.Product product
  WHERE NOT EXISTS (SELECT 1 FROM canon.ProductMedia brokenMedia
                    INNER JOIN val.MediaUrlCheck brokenCheck ON brokenCheck.IsBroken = 1
                      AND brokenCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(brokenMedia.Url))) AS binary(32))
                    WHERE brokenMedia.ProductId = product.ProductId)
     OR EXISTS (SELECT 1 FROM canon.ProductMedia workingMedia
                WHERE workingMedia.ProductId = product.ProductId AND NULLIF(LTRIM(RTRIM(workingMedia.Url)), N'''') IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM val.MediaUrlCheck workingCheck WHERE workingCheck.IsBroken = 1
                                    AND workingCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(workingMedia.Url))) AS binary(32))))
UNION ALL SELECT product.ProductId, N''ProductMedia.VseSlikeDelujejo'', N''1'' FROM canon.Product product
  WHERE NOT EXISTS (SELECT 1 FROM canon.ProductMedia brokenMedia
                    INNER JOIN val.MediaUrlCheck brokenCheck ON brokenCheck.IsBroken = 1
                      AND brokenCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(brokenMedia.Url))) AS binary(32))
                    WHERE brokenMedia.ProductId = product.ProductId)
     OR NOT EXISTS (SELECT 1 FROM canon.ProductMedia workingMedia
                WHERE workingMedia.ProductId = product.ProductId AND NULLIF(LTRIM(RTRIM(workingMedia.Url)), N'''') IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM val.MediaUrlCheck workingCheck WHERE workingCheck.IsBroken = 1
                                    AND workingCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(workingMedia.Url))) AS binary(32))))');
  SET @view = N'ALTER ' + SUBSTRING(@view, CHARINDEX(N'VIEW', @view), 2147483647);
  EXEC sys.sp_executesql @view;
END;
IF OBJECT_DEFINITION(OBJECT_ID(N'canon.FieldValue')) NOT LIKE N'%PreverjanjeSlik312%'
  THROW 53124, N'312: izpeljani polji slik nista v canon.FieldValue.', 1;
GO

/* 5) Zahteve: kjer profil zahteva sliko, zahteva tudi delujoco (napaka) in opozori na posamezno pokvarjeno. */
INSERT val.FieldRequirement (ValidationProfileId, FieldCode, IsRequired, IsActive, Severity)
SELECT imageRequirement.ValidationProfileId, derived.FieldCode, 1, 1, derived.Severity
FROM val.FieldRequirement AS imageRequirement
CROSS JOIN (VALUES (N'ProductMedia.DelujocaSlika', N'ERROR'), (N'ProductMedia.VseSlikeDelujejo', N'WARNING')) AS derived (FieldCode, Severity)
WHERE imageRequirement.FieldCode = N'ProductMedia.Url' AND imageRequirement.IsActive = 1 AND imageRequirement.IsRequired = 1
  AND imageRequirement.CategoryCode IS NULL
  AND NOT EXISTS (SELECT 1 FROM val.FieldRequirement AS existing
                  WHERE existing.ValidationProfileId = imageRequirement.ValidationProfileId AND existing.FieldCode = derived.FieldCode
                    AND existing.CategoryCode IS NULL);
GO

/* 6) out.GetExportRows: katalog.csv brez potrjeno pokvarjenih slik (zamenjava zive definicije). */
DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 53125, N'312: out.GetExportRows manjka.', 1;
IF @definition NOT LIKE N'%PreverjanjeSlik312%'
BEGIN
  DECLARE @media nvarchar(max) = N'INNER JOIN pim.ProductMedia AS media ON media.PimProductId = page.EntityId;';
  IF CHARINDEX(@media, @definition) = 0 OR LEN(@definition) - LEN(REPLACE(@definition, @media, N'')) <> LEN(@media)
    THROW 53126, N'312: blok medijev (B3) v out.GetExportRows ni v pricakovani obliki.', 1;
  SET @definition = REPLACE(@definition, @media, N'INNER JOIN pim.ProductMedia AS media ON media.PimProductId = page.EntityId
    /* PreverjanjeSlik312: potrjeno pokvarjena slika (2 neuspeha v razmiku 24 h, val.MediaUrlCheck) ne gre v katalog.csv. */
    WHERE NOT EXISTS (SELECT 1 FROM val.MediaUrlCheck AS brokenCheck
                      WHERE brokenCheck.IsBroken = 1
                        AND brokenCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(media.Url))) AS binary(32)));

    /* PreverjanjeSlik312: ce je bila glavna slika izpuscena, postane glavna prva preostala slika. */
    UPDATE firstMedia SET IsPrimary = 1
    FROM #Media AS firstMedia
    WHERE firstMedia.Ordinal = 1
      AND NOT EXISTS (SELECT 1 FROM #Media AS primaryMedia WHERE primaryMedia.RowKey = firstMedia.RowKey AND primaryMedia.IsPrimary = 1)
      AND EXISTS (SELECT 1 FROM #Page AS primaryPage
                  INNER JOIN pim.ProductMedia AS droppedMedia ON droppedMedia.PimProductId = primaryPage.EntityId
                  INNER JOIN val.MediaUrlCheck AS droppedCheck ON droppedCheck.IsBroken = 1
                    AND droppedCheck.UrlHash = CAST(HASHBYTES(''SHA2_256'', LTRIM(RTRIM(droppedMedia.Url))) AS binary(32))
                  WHERE primaryPage.RowKey = firstMedia.RowKey AND UPPER(droppedMedia.Role) IN (N''PRIMARY'', N''MAIN''));');
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%PreverjanjeSlik312%'
  THROW 53127, N'312: izpust pokvarjenih slik ni v out.GetExportRows.', 1;
GO

CREATE OR ALTER PROCEDURE intranet.GetMediaUrlChecks
  @OrganizationId int = NULL,
  @Search nvarchar(200) = NULL,
  @State nvarchar(20) = NULL,
  @Host nvarchar(255) = NULL,
  @ErrorCode nvarchar(40) = NULL,
  @Sort nvarchar(20) = NULL,
  @Descending bit = 0,
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  /* 312: /mediji/napacni-naslovi - slike aktivnih izdelkov, katerih naslov se ni odprl. Ena vrstica = ena slika
     izdelka (sifra + naslov); stanje je na naslovu (val.MediaUrlCheck). Samo branje.
     Stanja: POKVARJENA (potrjeno, 2 neuspeha v razmiku 24 h), SUMLJIVA (1 neuspeh, caka potrditev),
     NI_ODZIVA (strežnik ni odgovoril - ne steje). */
  SET NOCOUNT ON;
  SET @Skip = CASE WHEN @Skip IS NULL OR @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 50 WHEN @Take > 50000 THEN 50000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
  SET @State = NULLIF(@State, N'');
  SET @Host = NULLIF(@Host, N'');
  SET @ErrorCode = NULLIF(@ErrorCode, N'');

  CREATE TABLE #Media
  (
    ProductId bigint NOT NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL, OrganizationId int NOT NULL,
    Role nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, SortOrder int NOT NULL, Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
    UrlHash binary(32) NOT NULL
  );
  INSERT #Media (ProductId, ItemID, OrganizationId, Role, SortOrder, Url, UrlHash)
  SELECT product.ProductId, product.ItemID, product.OrganizationId, media.Role, media.SortOrder, media.Url,
    CAST(HASHBYTES('SHA2_256', LTRIM(RTRIM(media.Url))) AS binary(32))
  FROM canon.ProductMedia AS media
  INNER JOIN canon.Product AS product ON product.ProductId = media.ProductId
  WHERE product.IsActive = 1
    AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT config.OrganizationId FROM dbo.OrganizationConfig AS config WHERE config.IsActive = 1))
      OR product.OrganizationId = @OrganizationId)
    AND NULLIF(LTRIM(RTRIM(media.Url)), N'') IS NOT NULL;

  CREATE TABLE #Problem
  (
    ProductId bigint NOT NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL, OrganizationId int NOT NULL,
    Role nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, SortOrder int NOT NULL, Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
    Host nvarchar(255) COLLATE DATABASE_DEFAULT NULL, State nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
    LastHttpStatus int NULL, LastContentType nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
    LastErrorCode nvarchar(40) COLLATE DATABASE_DEFAULT NULL, LastErrorText nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    LastCheckedUtc datetime2(0) NULL, FirstFailedUtc datetime2(0) NULL, FailureCount int NOT NULL
  );
  INSERT #Problem
  SELECT media.ProductId, media.ItemID, media.OrganizationId, media.Role, media.SortOrder, media.Url, mediaCheck.Host,
    CASE WHEN mediaCheck.IsBroken = 1 THEN N'POKVARJENA' WHEN mediaCheck.FailureCount > 0 THEN N'SUMLJIVA' ELSE N'NI_ODZIVA' END,
    mediaCheck.LastHttpStatus, mediaCheck.LastContentType, mediaCheck.LastErrorCode, mediaCheck.LastErrorText,
    mediaCheck.LastCheckedUtc, mediaCheck.FirstFailedUtc, mediaCheck.FailureCount
  FROM #Media AS media
  INNER JOIN val.MediaUrlCheck AS mediaCheck ON mediaCheck.UrlHash = media.UrlHash
  WHERE mediaCheck.IsBroken = 1 OR mediaCheck.FailureCount > 0 OR mediaCheck.LastOutcome = N'NI_ODZIVA';

  /* Delujoca slika izdelka: vsaj ena slika, ki ni potrjeno pokvarjena. */
  CREATE TABLE #Working (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT #Working (ProductId)
  SELECT DISTINCT media.ProductId FROM #Media AS media
  WHERE media.ProductId IN (SELECT ProductId FROM #Problem)
    AND NOT EXISTS (SELECT 1 FROM val.MediaUrlCheck AS mediaCheck WHERE mediaCheck.UrlHash = media.UrlHash AND mediaCheck.IsBroken = 1);

  CREATE TABLE #Filtered
  (
    ProductId bigint NOT NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL, OrganizationId int NOT NULL,
    Role nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, SortOrder int NOT NULL, Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
    Host nvarchar(255) COLLATE DATABASE_DEFAULT NULL, State nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
    LastHttpStatus int NULL, LastContentType nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
    LastErrorCode nvarchar(40) COLLATE DATABASE_DEFAULT NULL, LastErrorText nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    LastCheckedUtc datetime2(0) NULL, FirstFailedUtc datetime2(0) NULL, FailureCount int NOT NULL, HasWorkingImage bit NOT NULL
  );
  INSERT #Filtered
  SELECT problem.*, CASE WHEN EXISTS (SELECT 1 FROM #Working AS working WHERE working.ProductId = problem.ProductId) THEN 1 ELSE 0 END
  FROM #Problem AS problem
  WHERE (@Host IS NULL OR problem.Host = @Host)
    AND (@ErrorCode IS NULL OR problem.LastErrorCode = @ErrorCode)
    AND (@Search IS NULL
      OR problem.ItemID COLLATE Latin1_General_CI_AI LIKE N'%' + @Search + N'%'
      OR problem.Url COLLATE Latin1_General_CI_AI LIKE N'%' + @Search + N'%');

  SELECT filtered.ProductId, filtered.ItemID, filtered.OrganizationId, organization.Name AS OrganizationName,
    filtered.Role, filtered.SortOrder, filtered.Url, filtered.Host, filtered.State, filtered.LastHttpStatus, filtered.LastContentType,
    filtered.LastErrorCode, filtered.LastErrorText, filtered.LastCheckedUtc, filtered.FirstFailedUtc, filtered.FailureCount,
    filtered.HasWorkingImage
  FROM #Filtered AS filtered
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = filtered.OrganizationId
  WHERE @State IS NULL OR filtered.State = @State
  ORDER BY
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N'sifra' THEN filtered.ItemID WHEN N'streznik' THEN filtered.Host WHEN N'napaka' THEN filtered.LastErrorCode END END,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N'sifra' THEN filtered.ItemID WHEN N'streznik' THEN filtered.Host WHEN N'napaka' THEN filtered.LastErrorCode END END DESC,
    CASE WHEN @Descending = 0 AND ISNULL(@Sort, N'') NOT IN (N'sifra', N'streznik', N'napaka') THEN filtered.LastCheckedUtc END,
    CASE WHEN @Descending = 1 AND ISNULL(@Sort, N'') NOT IN (N'sifra', N'streznik', N'napaka') THEN filtered.LastCheckedUtc END DESC,
    filtered.ItemID, filtered.SortOrder, filtered.Url
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT Total = COUNT_BIG(*) FROM #Filtered WHERE @State IS NULL OR State = @State;

  /* Stevci stanj pod ostalimi filtri (pilule); stevec je stevilo vrstic slik. */
  SELECT State, Items = COUNT_BIG(*), Products = COUNT_BIG(DISTINCT ProductId) FROM #Filtered GROUP BY State;

  SELECT Host = ISNULL(Host, N''), Items = COUNT_BIG(*) FROM #Problem GROUP BY Host ORDER BY COUNT_BIG(*) DESC;
  SELECT ErrorCode = ISNULL(LastErrorCode, N''), Items = COUNT_BIG(*) FROM #Problem GROUP BY LastErrorCode ORDER BY COUNT_BIG(*) DESC;

  /* Povzetek preverjanja za obseg: koliko naslovov je preverjenih in kdaj nazadnje. */
  SELECT
    Addresses = COUNT_BIG(DISTINCT media.UrlHash),
    Checked = COUNT_BIG(DISTINCT CASE WHEN mediaCheck.LastCheckedUtc IS NOT NULL THEN media.UrlHash END),
    LastCheckedUtc = MAX(mediaCheck.LastCheckedUtc),
    ProductsWithoutWorkingImage = (SELECT COUNT_BIG(DISTINCT problem.ProductId) FROM #Problem AS problem
                                   WHERE problem.State = N'POKVARJENA' AND NOT EXISTS (SELECT 1 FROM #Working AS working WHERE working.ProductId = problem.ProductId))
  FROM #Media AS media
  LEFT JOIN val.MediaUrlCheck AS mediaCheck ON mediaCheck.UrlHash = media.UrlHash;
END;
GO

/* 8) Razpored za ops.BeginRun: preverjanje je skupno vsem podjetjem, tece pod prvim aktivnim podjetjem.
   Vklop posla je v katalogu poslov (MEDIA_URL_CHECK, privzeto izklopljen), ne tu. */
DECLARE @organizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig WHERE IsActive = 1);
IF @organizationId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'MEDIA_URL_CHECK')
  INSERT ops.ScheduleProfile (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (@organizationId, N'LOCAL', N'MEDIA_URL_CHECK', 1, 7200, 14400, 0, N'migracija 312');
GO

IF OBJECT_ID(N'val.MediaUrlCheck', N'U') IS NULL OR OBJECT_ID(N'val.GetMediaUrlsToCheck', N'P') IS NULL
  OR OBJECT_ID(N'val.RecordMediaUrlChecks', N'P') IS NULL OR OBJECT_ID(N'intranet.GetMediaUrlChecks', N'P') IS NULL
  THROW 53128, N'312: objekti preverjanja slik manjkajo.', 1;
IF EXISTS (SELECT 1 FROM val.FieldRequirement WHERE FieldCode = N'ProductMedia.Url' AND IsActive = 1 AND IsRequired = 1 AND CategoryCode IS NULL)
  AND NOT EXISTS (SELECT 1 FROM val.FieldRequirement WHERE FieldCode = N'ProductMedia.DelujocaSlika' AND Severity = N'ERROR')
  THROW 53129, N'312: zahteva DelujocaSlika manjka.', 1;
