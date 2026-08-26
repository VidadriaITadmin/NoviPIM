/*
  099 — od kod se vir prevzame: mapa, HTTP ali FTP, kot vrstica registra.

  Odlocitev uporabnika 2026-08-26, po virih:

    NW izdelki   dobavitelj ima svojo PIM platformo; XML je treba potegniti ROCNO in
                 poloziti v mapo. Mapa zato ostane veljavno mesto prevzema, ne izjema.
    BT izdelki   URL, ki se sam osvezuje.
    NW zaloge    FTP dostop; poverilnice vpise uporabnik sam.
    BT zaloge    XML na HTTPS naslovu.

  "Kar imas narejeno braytron povezave naredi, ostale se bo na roke naknadno dodalo — treba je
  omogociti, da se lahko paketno ureja."

  --- Zakaj register in ne okoljske spremenljivke ------------------------------------------

  Doslej sta workerja mesto vhoda brala iz okolja (PIM_XML_ROOT in podobno). To pomeni, da je
  vsak nov vir sprememba nacrtovane naloge ali skripte, mnozicno urejanje pa ni mogoce. Register
  je ena tabela: nov vir je vrstica, sprememba desetih virov je en UPDATE, in intranet lahko nad
  njo naredi paketno urejanje brez posega v program.

  --- Zakaj naslova NI v tej datoteki ------------------------------------------------------

  Braytronov naslov ima obliko https://b2b.braytron.com/genel/xml/<GUID>. Ta GUID je dostopni
  kljuc: kdor ga ima, bere dobaviteljev XML. Migracije gredo v git, zato bi bil s tem kljuc v
  repozitoriju — AGENTS.md §5.5 to prepoveduje.

  Register zato hrani samo IME kljuca (CredentialKey), vrednost pa stoji v korenski
  appsettings.Local.json, ki je v .gitignore. Isto velja za FTP: v registru je "FTP" in ime
  kljuca, gostitelj in geslo pa vpise uporabnik lokalno.

      "Fetch": {
        "BT_STOCK": { "Url": "https://..." },
        "NW_STOCK": { "Host": "...", "Path": "...", "Username": "...", "Password": "..." }
      }

  --- Kar ta migracija NE naredi -----------------------------------------------------------

  Ne prevzame nicesar. Register samo pove, od kod se vir prevzame; koda, ki to izvede, je
  naslednji korak in prvi ziv prevzem je po §4.5 odlocitev cloveka.
*/

SET XACT_ABORT ON;

EXEC(N'
IF OBJECT_ID(N''map.SourceFetchLocation'') IS NULL
BEGIN
  CREATE TABLE map.SourceFetchLocation
  (
    SourceFetchLocationId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SourceFetchLocation PRIMARY KEY,
    OrganizationId  int            NULL,
    SourceCode      nvarchar(100)  NOT NULL,
    Kind            nvarchar(20)   NOT NULL,
    Location        nvarchar(1000) NULL,
    CredentialKey   nvarchar(200)  NULL,
    FileNamePattern nvarchar(200)  NULL,
    IsActive        bit            NOT NULL CONSTRAINT DF_SourceFetchLocation_IsActive DEFAULT(0),
    Note            nvarchar(600)  NULL,
    UpdatedUtc      datetime2(7)   NOT NULL CONSTRAINT DF_SourceFetchLocation_UpdatedUtc DEFAULT(SYSUTCDATETIME()),
    CONSTRAINT CK_SourceFetchLocation_Kind CHECK (Kind IN (N''MAPA'', N''HTTP'', N''FTP''))
  );

  /* NULL v OrganizationId pomeni "velja za vsa podjetja". SQL Server v unikatnem indeksu
     dva NULL-a steje za enaka, zato je takih vrstic na vir lahko natanko ena — kar je
     tocno zeljeno. Izraz v kljucu indeksa ni dovoljen, zato brez ISNULL. */
  CREATE UNIQUE INDEX UQ_SourceFetchLocation_Source
    ON map.SourceFetchLocation(SourceCode, OrganizationId);
END;
');

/* Ena vrstica na vir. Vrednosti brez naslova so namenoma nedejavne (IsActive = 0): vir, ki ne
   ve, od kod prevzeti, ne sme tiho delati nicesar in izgledati, kot da dela. */
MERGE map.SourceFetchLocation AS target
USING (VALUES
  (N'NW_XML',   N'MAPA', N'PIM_Solution\fixtures\nw', NULL,              N'*.xml',
   CONVERT(bit,1), N'Nowodvorski ima svojo PIM platformo. XML se potegne rocno in polozi v mapo.'),
  (N'BT_XML',   N'HTTP', NULL,                        N'Fetch:BT_XML',   N'braytron-izdelki.xml',
   CONVERT(bit,0), N'Dobavitelj se sam osvezuje. Naslov manjka — vpisi ga v appsettings.Local.json pod Fetch:BT_XML in postavi IsActive = 1.'),
  (N'NW_STOCK', N'FTP',  NULL,                        N'Fetch:NW_STOCK', N'nw-zaloga.csv',
   CONVERT(bit,0), N'FTP streznik dobavitelja, CSV. Gostitelja, mapo in poverilnice vpisi v appsettings.Local.json pod Fetch:NW_STOCK.'),
  (N'BT_STOCK', N'HTTP', NULL,                        N'Fetch:BT_STOCK', N'braytron-zaloga.xml',
   CONVERT(bit,1), N'XML na HTTPS naslovu z GUID-om. Naslov je dostopni kljuc, zato stoji v appsettings.Local.json pod Fetch:BT_STOCK in ne v tej migraciji.')
) AS source(SourceCode, Kind, Location, CredentialKey, FileNamePattern, IsActive, Note)
  ON target.SourceCode = source.SourceCode AND ISNULL(target.OrganizationId, 0) = 0
WHEN MATCHED THEN UPDATE SET
  Kind = source.Kind, FileNamePattern = source.FileNamePattern, Note = source.Note, UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (SourceCode, Kind, Location, CredentialKey, FileNamePattern, IsActive, Note)
  VALUES (source.SourceCode, source.Kind, source.Location, source.CredentialKey,
          source.FileNamePattern, source.IsActive, source.Note);
