/*
  065 — od kod beremo kolicine zaloge iz SAOP.

  Odlocitev uporabnika 2026-08-22: RegisteredViewData bi bil najbolji, a dela samo za Vidadrio
  (podjetje 3). Zato je GetStocks privzeti nacin za vsa stiri podjetja, Vidadria pa dobi se
  profil z registriranim pogledom, ki ima prednost.

  Zakaj to sploh potrebujemo: med sestnajstimi zajetimi koncnimi tockami dejanskih kolicin ni.
  GetItemsStockData nosi najmanjso in najvecjo zalogo po skladiscu, GetItemsStockAccountingData
  pa konte — kolicine so na locenem vmesniku (api/Stock/GetStocks oziroma registrirani pogled).

  Katera skladisca: endpoint potrebuje samo sifro, zato profil ne nosi seznama, ampak nacin
  izbire. 'ActiveFromRegister' pomeni "vsa aktivna skladisca podjetja iz canon.Warehouse" (064),
  kar je zdaj 4 pri DEMO, 35 pri IQLighting, 70 pri Vidadrii in 14 pri Ediitu. 'List' ostane za
  primer, ko bo treba zajeti samo del — takrat se sifre zapisejo v WarehouseIdsJson.

  Registrirani pogled je vpisan IZKLOPLJEN, ker njegove sifre (RegisteredViewId) se ne poznamo;
  dobi se z zivim klicem na api/registeredviews, kar je odlocitev uporabnika (AGENTS.md #4.5).
  Dokler je izklopljen, za Vidadrio velja GetStocks — podatek torej ni odvisen od tega koraka.
*/

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_SaopProviderProfile_Selection')
BEGIN
  ALTER TABLE stock.SaopProviderProfile WITH CHECK
    ADD CONSTRAINT CK_SaopProviderProfile_Selection
    CHECK (WarehouseSelectionMode IS NULL OR WarehouseSelectionMode IN (N'ActiveFromRegister', N'List'));
END;

MERGE stock.SaopProviderProfile AS target
USING (VALUES
  (1, N'SAOP_GETSTOCKS',        N'GetStocks',          10, CONVERT(bit,1), NULL, N'ActiveFromRegister'),
  (2, N'SAOP_GETSTOCKS',        N'GetStocks',          10, CONVERT(bit,1), NULL, N'ActiveFromRegister'),
  (3, N'SAOP_GETSTOCKS',        N'GetStocks',          10, CONVERT(bit,1), NULL, N'ActiveFromRegister'),
  (4, N'SAOP_GETSTOCKS',        N'GetStocks',          10, CONVERT(bit,1), NULL, N'ActiveFromRegister'),
  (3, N'SAOP_REGISTERED_VIEW',  N'RegisteredViewData',  5, CONVERT(bit,0), NULL, NULL)
) AS source(OrganizationId, ProfileCode, ProviderKind, Priority, Enabled, RegisteredViewId, WarehouseSelectionMode)
  ON target.OrganizationId = source.OrganizationId AND target.ProfileCode = source.ProfileCode
WHEN MATCHED THEN UPDATE SET
  ProviderKind = source.ProviderKind, Priority = source.Priority,
  WarehouseSelectionMode = source.WarehouseSelectionMode
WHEN NOT MATCHED THEN INSERT (OrganizationId, ProfileCode, ProviderKind, Priority, Enabled, RegisteredViewId, WarehouseSelectionMode)
  VALUES (source.OrganizationId, source.ProfileCode, source.ProviderKind, source.Priority, source.Enabled,
          source.RegisteredViewId, source.WarehouseSelectionMode);

/* --- preverbe -------------------------------------------------------------- */

IF (SELECT COUNT(*) FROM stock.SaopProviderProfile WHERE ProviderKind = N'GetStocks' AND Enabled = 1) < 4
  THROW 52651, 'GetStocks ni nastavljen za vsa stiri podjetja.', 1;

IF NOT EXISTS (SELECT 1 FROM stock.SaopProviderProfile WHERE OrganizationId = 3 AND ProviderKind = N'RegisteredViewData')
  THROW 52652, 'Vidadria nima profila z registriranim pogledom.', 1;

/* Vklopljen registrirani pogled brez sifre pogleda bi bil klic v prazno. */
IF EXISTS
(
  SELECT 1 FROM stock.SaopProviderProfile
  WHERE ProviderKind = N'RegisteredViewData' AND Enabled = 1 AND NULLIF(LTRIM(RTRIM(ISNULL(RegisteredViewId, N''))), N'') IS NULL
)
  THROW 52653, 'Registrirani pogled je vklopljen brez RegisteredViewId.', 1;
