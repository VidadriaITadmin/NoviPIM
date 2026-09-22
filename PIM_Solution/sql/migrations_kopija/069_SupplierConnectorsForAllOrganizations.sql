/*
  069 — dobavitelj se veze na vsa stiri podjetja, ne le na eno.

  Odlocitev uporabnika 2026-08-23: dobavitelj ni last enega podjetja. Njegov XML se mora vezati
  na vsa stiri podjetja in po EAN povezati svoje podatke z nasimi sifrantami.

  Zakaj je to pomembno v stevilkah. Isti EAN-i iz dobaviteljevih datotek se ujemajo takole:

    Nowodvorski (2.619 EAN):  IQLighting 2.543 | Vidadria 2.571 | DEMO 1.145 | nikjer 47
    Braytron    (3.074 EAN):  IQLighting   291 | Vidadria 1.086 | DEMO     7 | nikjer 1.980

  Konektorja sta bila registrirana samo za podjetje 2, zato Vidadria ni dobila ne lastnosti ne
  kategorij ne slik — pri Braytronu skoraj stirikrat vec ujemanj kot IQLighting.

  Kaj ta migracija naredi: za podjetja 1, 3 in 4 ustvari konektorja NW_XML in BT_XML ter jima
  prepise entitete, preslikave in pretvorbe s konektorja podjetja 2. Nic ni prepisano na novo;
  vir resnice ostaja ena sama nastavitev, ki je bila ze dokazana (054, 055, 059).

  Kar se NE spremeni: pravica ustvarjanja artikla. Dobaviteljev konektor ostaja
  CanCreateProducts = 0 — dobavitelj ne sme ustvariti artikla v katalogu. Sifra artikla je last
  SAOP (stolpec "Master" v preglednici, migracija 068), zato gre nova dobaviteljeva sifra najprej
  v SAOP in sele od tam v PIM. Zapis, ki se ne ujame z nobenim artiklom, se preskoci in ostane
  viden v raw.Inbox; delovni seznam zanj je naslednji korak.
*/

SET XACT_ABORT ON;

DECLARE @Viri TABLE(SourceCode nvarchar(100) PRIMARY KEY);
INSERT @Viri(SourceCode) VALUES (N'NW_XML'), (N'BT_XML');

DECLARE @Podjetja TABLE(OrganizationId int PRIMARY KEY);
INSERT @Podjetja(OrganizationId) VALUES (1), (3), (4);

/* --- 1) konektor za vsako podjetje ---------------------------------------- */

MERGE map.SourceConnector AS target
USING
(
  SELECT vir.SourceCode, podjetje.OrganizationId, izvor.ConnectorType
  FROM @Viri vir
  CROSS JOIN @Podjetja podjetje
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = vir.SourceCode AND izvor.OrganizationId = 2
) source
  ON target.SourceCode = source.SourceCode AND target.OrganizationId = source.OrganizationId
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive)
  VALUES (source.SourceCode, source.OrganizationId, source.ConnectorType, 1);

/* --- 2) entitete ------------------------------------------------------------ */

MERGE map.EntityMapping AS target
USING
(
  SELECT cilj.SourceConnectorId, izvorna.EntityType, izvorna.RecordXPath, izvorna.TargetDomain, izvorna.IsActive
  FROM map.SourceConnector cilj
  INNER JOIN @Viri vir ON vir.SourceCode = cilj.SourceCode
  INNER JOIN @Podjetja podjetje ON podjetje.OrganizationId = cilj.OrganizationId
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = cilj.SourceCode AND izvor.OrganizationId = 2
  INNER JOIN map.EntityMapping izvorna ON izvorna.SourceConnectorId = izvor.SourceConnectorId
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, source.IsActive);

/* --- 3) preslikave polj ----------------------------------------------------- */

MERGE map.FieldMapping AS target
USING
(
  SELECT cilj.SourceConnectorId, izvorna.EntityType, izvorna.SourceElement, izvorna.TargetFieldCode,
    izvorna.IsRequired, izvorna.IsActive
  FROM map.SourceConnector cilj
  INNER JOIN @Viri vir ON vir.SourceCode = cilj.SourceCode
  INNER JOIN @Podjetja podjetje ON podjetje.OrganizationId = cilj.OrganizationId
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = cilj.SourceCode AND izvor.OrganizationId = 2
  INNER JOIN map.FieldMapping izvorna ON izvorna.SourceConnectorId = izvor.SourceConnectorId
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode,
          source.IsRequired, source.IsActive);

/* --- 4) pretvorbe vrednosti ------------------------------------------------- */

/*
  Pretvorba visi na preslikavi, zato se prenese prek para (entiteta, ciljna koda): za vsako
  preslikavo novega konektorja poiscemo istolezno preslikavo podjetja 2 in prepisemo njene korake.
*/
MERGE map.FieldTransform AS target
USING
(
  SELECT ciljna.FieldMappingId, izvornaPretvorba.StepOrder, izvornaPretvorba.TransformCode, izvornaPretvorba.Argument
  FROM map.FieldMapping ciljna
  INNER JOIN map.SourceConnector cilj ON cilj.SourceConnectorId = ciljna.SourceConnectorId
  INNER JOIN @Viri vir ON vir.SourceCode = cilj.SourceCode
  INNER JOIN @Podjetja podjetje ON podjetje.OrganizationId = cilj.OrganizationId
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = cilj.SourceCode AND izvor.OrganizationId = 2
  INNER JOIN map.FieldMapping izvornaPreslikava ON izvornaPreslikava.SourceConnectorId = izvor.SourceConnectorId
    AND izvornaPreslikava.EntityType = ciljna.EntityType AND izvornaPreslikava.TargetFieldCode = ciljna.TargetFieldCode
  INNER JOIN map.FieldTransform izvornaPretvorba ON izvornaPretvorba.FieldMappingId = izvornaPreslikava.FieldMappingId
) source
  ON target.FieldMappingId = source.FieldMappingId AND target.StepOrder = source.StepOrder
WHEN MATCHED THEN UPDATE SET TransformCode = source.TransformCode, Argument = source.Argument
WHEN NOT MATCHED THEN INSERT (FieldMappingId, StepOrder, TransformCode, Argument)
  VALUES (source.FieldMappingId, source.StepOrder, source.TransformCode, source.Argument);

/* --- 5) preverbe ------------------------------------------------------------ */

IF (SELECT COUNT(*) FROM map.SourceConnector WHERE SourceCode IN (N'NW_XML', N'BT_XML') AND IsActive = 1) < 8
  THROW 52691, 'Dobaviteljska konektorja nista registrirana pri vseh stirih podjetjih.', 1;

/* Vsak nov konektor mora imeti enako sliko kot izvorni; drugace bi tiho zajemal manj. */
IF EXISTS
(
  SELECT 1
  FROM map.SourceConnector cilj
  INNER JOIN map.SourceConnector izvor ON izvor.SourceCode = cilj.SourceCode AND izvor.OrganizationId = 2
  WHERE cilj.SourceCode IN (N'NW_XML', N'BT_XML') AND cilj.OrganizationId <> 2
    AND (
      (SELECT COUNT(*) FROM map.FieldMapping m WHERE m.SourceConnectorId = cilj.SourceConnectorId)
        <> (SELECT COUNT(*) FROM map.FieldMapping m WHERE m.SourceConnectorId = izvor.SourceConnectorId)
      OR (SELECT COUNT(*) FROM map.EntityMapping e WHERE e.SourceConnectorId = cilj.SourceConnectorId)
        <> (SELECT COUNT(*) FROM map.EntityMapping e WHERE e.SourceConnectorId = izvor.SourceConnectorId)
    )
)
  THROW 52692, 'Prepis preslikav dobavitelja ni popoln.', 1;

/* Dobavitelj ne sme ustvariti artikla: sifra je last SAOP. */
IF EXISTS (SELECT 1 FROM map.SourceConnector WHERE SourceCode IN (N'NW_XML', N'BT_XML') AND CanCreateProducts = 1)
  THROW 52693, 'Dobaviteljev konektor ima pravico ustvarjanja artikla.', 1;
