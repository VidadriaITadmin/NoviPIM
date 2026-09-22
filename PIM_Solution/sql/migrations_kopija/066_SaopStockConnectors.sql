/*
  066 — konektorji in pravila identitete za zalogo iz SAOP.

  Zaloga ima svoj konektor, tako kot pri dobaviteljih (NW_STOCK, BT_STOCK). Katalog in zaloga
  sta dva razlicna tokova z razlicnima pravilima ujemanja, zato ne delita vrstice registra.

  Ujemanje je po sifri artikla brez predpone: SAOP poslje naso sifro, ne dobaviteljeve. Prav
  zato je zaloga iz SAOP nekaj drugega od zaloge dobavitelja, kjer je predpona (NW., BA.)
  edini nacin, da se tuja sifra prevede v naso.
*/

SET XACT_ABORT ON;

MERGE map.SourceConnector AS target
USING (VALUES
  (N'SAOP_DEMO_STOCK',       1),
  (N'SAOP_IQLIGHTING_STOCK', 2),
  (N'SAOP_VIDADRIA_STOCK',   3),
  (N'SAOP_EDIITO_STOCK',     4)
) AS source(SourceCode, OrganizationId)
  ON target.SourceCode = source.SourceCode AND target.OrganizationId = source.OrganizationId
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive)
  VALUES (source.SourceCode, source.OrganizationId, N'SAOP', 1);

MERGE map.StockIdentityRule AS target
USING
(
  SELECT connector.SourceConnectorId, N'SourceItemId' AS SourceKeyField, N'' AS Prefix, N'ItemID' AS MatchPriority
  FROM map.SourceConnector connector
  WHERE connector.SourceCode IN (N'SAOP_DEMO_STOCK', N'SAOP_IQLIGHTING_STOCK', N'SAOP_VIDADRIA_STOCK', N'SAOP_EDIITO_STOCK')
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.SourceKeyField = source.SourceKeyField
WHEN MATCHED THEN UPDATE SET Prefix = source.Prefix, MatchPriority = source.MatchPriority, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, SourceKeyField, Prefix, MatchPriority, IsActive)
  VALUES (source.SourceConnectorId, source.SourceKeyField, source.Prefix, source.MatchPriority, 1);

/* --- preverba -------------------------------------------------------------- */

IF
(
  SELECT COUNT(*)
  FROM map.StockIdentityRule pravilo
  INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = pravilo.SourceConnectorId
  WHERE connector.SourceCode LIKE N'SAOP%_STOCK' AND pravilo.IsActive = 1
) < 4
  THROW 52661, 'Pravila identitete za zalogo iz SAOP niso nastavljena za vsa stiri podjetja.', 1;
