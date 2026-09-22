/*
  227 — Vloge niso več samo štiri kode v programu. Skrbnik lahko ustvari svojo vlogo in ji
  določi vidnost vsake glavne strani ter posameznega zavihka/podstrani.

  Katalog poti ostaja v aplikaciji (PimAccessCatalog), ker se spreminja skupaj z Razor stranmi.
  Tu hranimo samo stabilen ključ dodelitve. Obstoječim štirim vlogam se nastavi enak oziroma
  ožji dostop, kot so ga pred migracijo določali [Authorize] in stranski meni.
*/

SET XACT_ABORT ON;

IF COL_LENGTH(N'sec.Role', N'Description') IS NULL
  ALTER TABLE sec.Role ADD Description nvarchar(400) NULL;

IF COL_LENGTH(N'sec.Role', N'IsSystem') IS NULL
  ALTER TABLE sec.Role ADD IsSystem bit NOT NULL
    CONSTRAINT DF_Role_IsSystem DEFAULT (0);

/* EXEC, ne navaden UPDATE: brez tega SQL Server ob prvem teku (Description/IsSystem se ne
   obstajata) preveri imena stolpcev za CEL batch, se preden ALTER TABLE zgoraj sploh izvede -
   in UPDATE pade z "Invalid column name". Znotraj EXEC se preverba zgodi sele ob izvajanju. */
EXEC(N'
UPDATE sec.Role
SET IsSystem = CASE WHEN RoleCode IN (N''ADMIN'', N''CATALOG_EDITOR'', N''COMMERCIAL'', N''VIEWER'') THEN 1 ELSE IsSystem END,
    Description = COALESCE(Description, CASE RoleCode
      WHEN N''ADMIN'' THEN N''Poln dostop in upravljanje uporabnikov, vlog ter sistema.''
      WHEN N''CATALOG_EDITOR'' THEN N''Urejanje kataloga, kakovosti ter izhodov v SAOP in splet.''
      WHEN N''COMMERCIAL'' THEN N''Poslovni podatki, stranke, pravila in nastavitve kataloga.''
      WHEN N''VIEWER'' THEN N''Bralni dostop do vsakodnevnih pregledov brez upravljanja sistema.''
      ELSE NULL END);
');

IF OBJECT_ID(N'sec.RolePermission', N'U') IS NULL
BEGIN
  CREATE TABLE sec.RolePermission
  (
    RoleId int NOT NULL,
    PermissionKey nvarchar(100) NOT NULL,
    CONSTRAINT PK_RolePermission PRIMARY KEY (RoleId, PermissionKey),
    CONSTRAINT FK_RolePermission_Role FOREIGN KEY (RoleId) REFERENCES sec.Role(RoleId) ON DELETE CASCADE,
    CONSTRAINT CK_RolePermission_Key CHECK (PermissionKey LIKE N'page.%' OR PermissionKey LIKE N'tab.%' OR PermissionKey LIKE N'view.%')
  );
END;

/* Odvzeto dovoljenje ne sme ostati živo v odprtem Blazor vezju. Enak vzorec kot pri spremembi
   dodeljene vloge (181): uporabniku zavrtimo varnostni žig, validator pa prekine staro sejo. */
EXEC(N'
CREATE OR ALTER TRIGGER sec.TR_RolePermission_SecurityStamp
ON sec.RolePermission
AFTER INSERT, DELETE
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE localUser
    SET SecurityStamp = NEWID()
  FROM sec.LocalUser localUser
  INNER JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
  WHERE userRole.RoleId IN (
    SELECT RoleId FROM inserted
    UNION
    SELECT RoleId FROM deleted);
END;
');

DECLARE @Permission TABLE
(
  PermissionKey nvarchar(100) NOT NULL PRIMARY KEY,
  Viewer bit NOT NULL,
  CatalogEditor bit NOT NULL,
  Commercial bit NOT NULL
);

INSERT @Permission (PermissionKey, Viewer, CatalogEditor, Commercial) VALUES
  (N'page.dashboard', 1, 1, 1),

  (N'page.ingest', 1, 1, 1),
  (N'tab.ingest.overview', 1, 1, 1),
  (N'tab.ingest.runs', 1, 1, 1),
  (N'tab.ingest.issues', 1, 1, 1),
  (N'view.ingest.candidates', 1, 1, 1),
  (N'view.ingest.queue', 1, 1, 1),
  (N'view.ingest.unmapped', 1, 1, 1),
  (N'view.ingest.attributes', 0, 1, 0),

  (N'page.products', 1, 1, 1),
  (N'view.products.list', 1, 1, 1),
  (N'view.products.import', 0, 1, 1),
  (N'view.products.categories', 0, 1, 0),
  (N'page.media', 1, 1, 1),

  (N'page.quality', 1, 1, 1),
  (N'tab.quality.products', 1, 1, 1),
  (N'tab.quality.validation', 1, 1, 1),
  (N'tab.quality.quarantine', 1, 1, 1),
  (N'tab.quality.translations', 1, 1, 1),
  (N'tab.quality.categories', 1, 1, 1),
  (N'tab.quality.by-category', 1, 1, 1),
  (N'view.quality.profiles', 1, 1, 1),

  (N'page.saop', 0, 1, 0),
  (N'tab.saop.items', 0, 1, 0),
  (N'tab.saop.queue', 0, 1, 0),
  (N'tab.saop.history', 0, 1, 0),
  (N'tab.saop.overview', 0, 1, 0),
  (N'view.saop.drifts', 0, 1, 0),
  (N'view.saop.fields', 0, 1, 0),

  (N'page.web', 1, 1, 1),
  (N'view.web.overview', 1, 1, 1),
  (N'view.web.build', 1, 1, 1),
  (N'view.web.catalog', 0, 1, 0),
  (N'view.web.profiles', 1, 1, 1),
  (N'view.web.events', 0, 1, 1),
  (N'view.web.bulk', 0, 1, 1),

  (N'page.customers', 0, 1, 1),
  (N'view.customers.list', 0, 1, 1),
  (N'view.customers.partners', 0, 1, 1),
  (N'page.stocks', 1, 1, 1),
  (N'page.prices', 1, 1, 1),
  (N'page.checks', 1, 1, 1),

  (N'page.catalog-settings', 0, 1, 1),
  (N'view.catalog.attributes', 0, 1, 1),
  (N'view.catalog.categories', 0, 1, 1),
  (N'view.catalog.attribute-sets', 0, 1, 1),
  (N'view.catalog.product-links', 0, 1, 1),
  (N'view.catalog.channels', 0, 1, 1),
  (N'view.catalog.languages', 0, 1, 1),
  (N'view.catalog.warehouses', 0, 1, 1),
  (N'view.catalog.reservations', 0, 1, 1),

  (N'page.rules', 0, 1, 1),
  (N'view.rules.validation', 0, 1, 1),
  (N'view.rules.dictionary', 0, 1, 1),
  (N'view.rules.mappings', 0, 1, 1),
  (N'view.rules.discounts', 0, 1, 1),
  (N'view.rules.titles', 0, 1, 0),

  (N'page.system', 0, 0, 0),
  (N'tab.system.overview', 0, 0, 0),
  (N'tab.system.schedules', 0, 0, 0),
  (N'tab.system.workers', 0, 0, 0),
  (N'tab.system.alerts', 0, 0, 0),
  (N'view.system.activity', 0, 0, 0),
  (N'view.system.exports', 0, 0, 0),
  (N'view.system.performance', 0, 0, 0),
  (N'view.system.self-test', 0, 0, 0),
  (N'view.system.errors', 0, 0, 0),

  (N'page.administration', 0, 0, 0),
  (N'tab.admin.users', 0, 0, 0),
  (N'tab.admin.roles', 0, 0, 0),
  (N'tab.admin.paths', 0, 0, 0);

/* ADMIN je v kodi dodatno varovan kot vedno-poln dostop; vrstice vseeno zapišemo, da števec in
   pregled vloge jasno pokažeta celoten obseg. */
INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, permission.PermissionKey
FROM sec.Role roleValue
CROSS JOIN @Permission permission
WHERE roleValue.RoleCode = N'ADMIN'
  AND NOT EXISTS (
    SELECT 1 FROM sec.RolePermission existing
    WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = permission.PermissionKey);

INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, permission.PermissionKey
FROM sec.Role roleValue
CROSS JOIN @Permission permission
WHERE ((roleValue.RoleCode = N'VIEWER' AND permission.Viewer = 1)
   OR (roleValue.RoleCode = N'CATALOG_EDITOR' AND permission.CatalogEditor = 1)
   OR (roleValue.RoleCode = N'COMMERCIAL' AND permission.Commercial = 1))
  AND NOT EXISTS (
    SELECT 1 FROM sec.RolePermission existing
    WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = permission.PermissionKey);

IF OBJECT_ID(N'sec.RolePermission', N'U') IS NULL
  THROW 51227, N'227: sec.RolePermission manjka.', 1;
IF OBJECT_ID(N'sec.TR_RolePermission_SecurityStamp', N'TR') IS NULL
  THROW 51227, N'227: sprožilec dovoljenj manjka.', 1;
