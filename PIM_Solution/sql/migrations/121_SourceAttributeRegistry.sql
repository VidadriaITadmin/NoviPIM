/*
  121 — register izvornih atributov: kaj je dobavitelj poslal in koliko izdelkov je za tem.

  --- Zakaj ga do zdaj ni bilo in zakaj to boli --------------------------------------------

  Za kategorije register obstaja od migracije 091: map.SourceCategory sam zapise vsako pot, ki
  jo je vir poslal, tudi kadar zanjo ni preslikave. Zato se vidi, kaj caka.

  Za atribute tega ni. Izlusci se natanko tisto, kar je v map.FieldMapping, vse ostalo pa se
  nikoli ne prebere in zato ne obstaja. Nepreslikan atribut ni napaka, ni opozorilo in ni
  vrstica nikjer - preprosto ga ni.

  Izmerjeno rocno 2026-08-27 nad Braytronovo datoteko: od 66 atributov jih 6 ne gre nikamor
  (type, sensor_type, led_quantity, capacity_watt, weight, ean). Stiri od njih so v
  uporabnikovem slovarju poimenovani. Sistem tega ne bi javil nikoli.

  --- Zakaj odkrivanje ni v kodi ------------------------------------------------------------

  Oba dobavitelja nosita atribute drugace:

    Nowodvorski   <attributes><attribute_ip><ip_name>IP</ip_name><ip_value>IP20</ip_value>
                  <ip_unit/></attribute_ip>...</attributes>          ime = ime elementa
    Braytron      <attribute><slug>ip</slug><title>IP</title>
                  <value>IP65</value></attribute>                    ime = slug

  Zato je odkrivanje vrstica registra in ne pogoj v programu: nov dobavitelj doda vrstico v
  map.SourceAttributeDiscovery in worker ga zna prebrati, ne da bi se karkoli prevedlo znova.
  To je isto nacelo kot pri map.FieldMapping - "nov dobavitelj je vrstica, ne razlicica".

  --- Kaj ta migracija NE naredi ------------------------------------------------------------

  Ne preslika nobenega atributa in ne spremeni nobene vrednosti. Samo omogoci, da se vidi,
  kaj je prislo.
*/

SET XACT_ABORT ON;

/* --- 1) Kako se pri viru najde atribut ---------------------------------------------------- */

EXEC(N'
IF OBJECT_ID(N''map.SourceAttributeDiscovery'') IS NULL
BEGIN
  CREATE TABLE map.SourceAttributeDiscovery
  (
    SourceAttributeDiscoveryId int IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_SourceAttributeDiscovery PRIMARY KEY,
    SourceCode  nvarchar(100) NOT NULL,
    EntityType  nvarchar(100) NOT NULL,
    /* Pot do posameznega atributa, relativna na zapis izdelka. */
    NodeXPath   nvarchar(400) NOT NULL,
    /* Ime atributa. Prazno pomeni: uporabi ime elementa (local-name). */
    NameXPath   nvarchar(400) NULL,
    /* Cloveku berljiva oznaka, vrednost in enota - vse neobvezno, vse samo za register. */
    LabelXPath  nvarchar(400) NULL,
    ValueXPath  nvarchar(400) NULL,
    UnitXPath   nvarchar(400) NULL,
    IsActive    bit NOT NULL CONSTRAINT DF_SourceAttributeDiscovery_IsActive DEFAULT(1),
    Note        nvarchar(600) NULL,
    CONSTRAINT UQ_SourceAttributeDiscovery UNIQUE (SourceCode, EntityType)
  );
END;
');

/* --- 2) Kaj je vir poslal ------------------------------------------------------------------ */

EXEC(N'
IF OBJECT_ID(N''map.SourceAttribute'') IS NULL
BEGIN
  CREATE TABLE map.SourceAttribute
  (
    SourceAttributeId int IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_SourceAttribute PRIMARY KEY,
    SourceCode          nvarchar(100)  NOT NULL,
    SourceAttributeName nvarchar(400)  NOT NULL,
    SourceLabel         nvarchar(400)  NULL,
    SampleValue         nvarchar(1000) NULL,
    SampleUnit          nvarchar(100)  NULL,
    ProductCount        int            NOT NULL CONSTRAINT DF_SourceAttribute_ProductCount DEFAULT(0),
    FirstSeenUtc        datetime2(7)   NOT NULL CONSTRAINT DF_SourceAttribute_FirstSeenUtc DEFAULT(SYSUTCDATETIME()),
    LastSeenUtc         datetime2(7)   NOT NULL CONSTRAINT DF_SourceAttribute_LastSeenUtc DEFAULT(SYSUTCDATETIME()),
    CONSTRAINT UQ_SourceAttribute UNIQUE (SourceCode, SourceAttributeName)
  );
  CREATE INDEX IX_SourceAttribute_Pogostost ON map.SourceAttribute(SourceCode, ProductCount DESC);
END;
');

/* --- 3) Zapis najdenega -------------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.RegisterSourceAttributes
  @SourceCode nvarchar(100),
  @FoundJson nvarchar(max)   /* [{"name":"ip","label":"IP","value":"IP65","unit":null,"count":2844}] */
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Najdeno TABLE
  (
    SourceAttributeName nvarchar(400) NOT NULL PRIMARY KEY,
    SourceLabel nvarchar(400) NULL,
    SampleValue nvarchar(1000) NULL,
    SampleUnit nvarchar(100) NULL,
    ProductCount int NOT NULL
  );

  INSERT @Najdeno (SourceAttributeName, SourceLabel, SampleValue, SampleUnit, ProductCount)
  SELECT LTRIM(RTRIM(vrstica.name)), NULLIF(LTRIM(RTRIM(vrstica.label)), N''''),
         NULLIF(LTRIM(RTRIM(vrstica.value)), N''''), NULLIF(LTRIM(RTRIM(vrstica.unit)), N''''),
         ISNULL(vrstica.count, 0)
  FROM OPENJSON(@FoundJson)
    WITH (name nvarchar(400) N''$.name'', label nvarchar(400) N''$.label'',
          value nvarchar(1000) N''$.value'', unit nvarchar(100) N''$.unit'',
          count int N''$.count'') vrstica
  WHERE NULLIF(LTRIM(RTRIM(vrstica.name)), N'''') IS NOT NULL;

  /*
    Stevec je najvecji doslej videni, ne zadnji. En zajem lahko prinese le del kataloga (delta,
    --max-pages, ena stran); ce bi stevec prepisali, bi atribut z 2.844 izdelki naslednji dan
    padel na 3 in izgledal nepomemben.
  */
  MERGE map.SourceAttribute AS target
  USING @Najdeno AS source
    ON target.SourceCode = @SourceCode AND target.SourceAttributeName = source.SourceAttributeName
  WHEN MATCHED THEN UPDATE SET
    SourceLabel  = COALESCE(source.SourceLabel, target.SourceLabel),
    SampleValue  = COALESCE(source.SampleValue, target.SampleValue),
    SampleUnit   = COALESCE(source.SampleUnit, target.SampleUnit),
    ProductCount = CASE WHEN source.ProductCount > target.ProductCount THEN source.ProductCount ELSE target.ProductCount END,
    LastSeenUtc  = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT
    (SourceCode, SourceAttributeName, SourceLabel, SampleValue, SampleUnit, ProductCount)
    VALUES (@SourceCode, source.SourceAttributeName, source.SourceLabel, source.SampleValue,
            source.SampleUnit, source.ProductCount);

  SELECT COUNT(*) AS Registered FROM @Najdeno;
END;
');

/* --- 4) Kako se bereta obstojeca vira ------------------------------------------------------ */

EXEC(N'
MERGE map.SourceAttributeDiscovery AS target
USING
(
  /*
    Nowodvorski: en element na atribut, ime atributa je ime elementa. Oznaka, vrednost in enota
    so otroci s pripono _name, _value, _unit; XPath 1.0 jih naslovi po koncnici imena, ker je
    predpona pri vsakem atributu druga (ip_name, frequency_name, ...).
  */
  SELECT N''NW_XML'' AS SourceCode, N''Attribute'' AS EntityType,
         N''attributes/*'' AS NodeXPath,
         CAST(NULL AS nvarchar(400)) AS NameXPath,
         N''*[substring(local-name(), string-length(local-name()) - 4) = "_name"]'' AS LabelXPath,
         N''*[substring(local-name(), string-length(local-name()) - 5) = "_value"]'' AS ValueXPath,
         N''*[substring(local-name(), string-length(local-name()) - 4) = "_unit"]'' AS UnitXPath,
         N''Ime atributa je ime elementa; oznaka, vrednost in enota so otroci s pripono.'' AS Note
  UNION ALL
  /* Braytron: ena oblika za vse atribute, razlocuje jih slug. Enote v zapisu ni. */
  SELECT N''BT_XML'', N''Attribute'',
         N''.//attribute'', N''slug/text()'', N''title/text()'', N''value/text()'', NULL,
         N''Ena oblika za vse atribute; razlocevalec je slug, enote v zapisu ni.''
) AS source
  ON target.SourceCode = source.SourceCode AND target.EntityType = source.EntityType
WHEN MATCHED THEN UPDATE SET
  NodeXPath = source.NodeXPath, NameXPath = source.NameXPath, LabelXPath = source.LabelXPath,
  ValueXPath = source.ValueXPath, UnitXPath = source.UnitXPath, IsActive = 1, Note = source.Note
WHEN NOT MATCHED THEN INSERT
  (SourceCode, EntityType, NodeXPath, NameXPath, LabelXPath, ValueXPath, UnitXPath, IsActive, Note)
  VALUES (source.SourceCode, source.EntityType, source.NodeXPath, source.NameXPath,
          source.LabelXPath, source.ValueXPath, source.UnitXPath, 1, source.Note);
');
