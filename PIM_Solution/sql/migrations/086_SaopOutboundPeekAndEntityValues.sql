/*
  086 — suhi tek odhodne poti in kanonicne vrednosti po entiteti.

  Dve stvari, ki manjkata, da se da odhodna pot preizkusiti, ne da bi karkoli odslo:

  1) out.PeekItemDocuments — pokaze, kaj bi bilo poslano, brez prevzema.
     Zakaj svoja procedura in ne out.ClaimItemDocument: prevzem POVECA stevilo poskusov in
     postavi lease. Ce bi suhi tek uporabljal prevzem, bi vsak pregled porabil en poskus in
     bi sporocilo po nekaj pregledih umrlo od poskusov, ki se niso zgodili. Enako past je
     imel dispatcher pred 2026-08 pri manjkajocem razporedu.

  2) out.GetSaopEntityValues — kanonicne vrednosti za katerokoli entiteto.
     Pri spremembi (PATCH) se poslje samo tisto, kar je urednik spremenil, in te vrednosti so
     ze v vrsti. Pri ustvarjanju (ADD) pa mora dokument nositi VSA obvezna polja, tudi tista,
     ki jih nihce ni spreminjal. Zato zna pot ob ustvarjanju dopolniti manjkajoce iz
     kanonicnega modela.

  Poste no o mejah: kanonicne vrednosti so danes na voljo samo za izdelke. Stranke jih nimajo,
  ker ima b2b.Customer 0 vrstic in stiri stolpce; cene in ceniki jih nimajo, ker po sprejeti
  preslikavi niso v lasti PIM in zanje ADD ne obstaja. Procedura zato za te tri entitete vrne
  prazen nabor — namenoma in vidno, ne tiho.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE out.PeekItemDocuments
  @OrganizationId int = NULL, @TargetKind nvarchar(100) = N''SAOP_PRODUCT'', @Top int = 50
AS
BEGIN
  SET NOCOUNT ON;

  /* Dokumenti, ki bi bili prevzeti ob naslednjem zagonu, po istem merilu kot prevzem —
     brez pogoja o omogocenem profilu, ker je suhi tek namenjen prav preverjanju PRED tem,
     da se profil omogoci. */
  ;WITH pripravljeni AS
  (
    SELECT message.OrganizationId, message.EntityKey,
      Sporocil = COUNT(*),
      Najstarejse = MIN(message.OutboxMessageId),
      Poskusov = MAX(message.AttemptCount),
      ZadnjaNapaka = MAX(message.SaopErrorKind)
    FROM out.OutboxMessage AS message
    WHERE message.TargetKind = @TargetKind
      AND (@OrganizationId IS NULL OR message.OrganizationId = @OrganizationId)
      AND message.Status IN (N''Pending'', N''Retry'')
      AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    GROUP BY message.OrganizationId, message.EntityKey
  )
  SELECT TOP(@Top) pripravljeni.OrganizationId, pripravljeni.EntityKey, pripravljeni.Sporocil,
    pripravljeni.Poskusov, pripravljeni.ZadnjaNapaka,
    ExistsInSaop = CONVERT(bit, CASE WHEN EXISTS
      (SELECT 1 FROM canon.Product WHERE OrganizationId = pripravljeni.OrganizationId AND ItemID = pripravljeni.EntityKey)
      THEN 1 ELSE 0 END),
    SourceKey = CASE WHEN CHARINDEX(N''.'', pripravljeni.EntityKey) > 1
      THEN UPPER(LEFT(pripravljeni.EntityKey, CHARINDEX(N''.'', pripravljeni.EntityKey) - 1)) ELSE N''*'' END
  FROM pripravljeni
  ORDER BY pripravljeni.Najstarejse;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopEntityChanges
  @OrganizationId int, @TargetKind nvarchar(100), @EntityKey nvarchar(450)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT message.OutboxMessageId, FieldKey = message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''), message.Status, message.AttemptCount
  FROM out.OutboxMessage AS message
  WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = @TargetKind
    AND message.EntityKey = @EntityKey
    AND message.Status IN (N''Pending'', N''Retry'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
  ORDER BY message.OutboxMessageId;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSaopEntityValues
  @OrganizationId int, @TargetKind nvarchar(100), @EntityKey nvarchar(450)
AS
BEGIN
  SET NOCOUNT ON;

  IF @TargetKind = N''SAOP_PRODUCT''
  BEGIN
    EXEC out.GetSaopItemWriteState @OrganizationId = @OrganizationId, @ItemID = @EntityKey;
    RETURN;
  END;

  IF @TargetKind = N''SAOP_CUSTOMER''
  BEGIN
    DECLARE @CustomerId bigint =
      (SELECT TOP(1) CustomerId FROM b2b.Customer WHERE OrganizationId = @OrganizationId AND CustomerKey = @EntityKey);

    SELECT ProductId = @CustomerId, ItemID = @EntityKey, SourceKey = N''*'',
      ExistsInSaop = CONVERT(bit, CASE WHEN @CustomerId IS NULL THEN 0 ELSE 1 END);

    SELECT value.FieldKey, value.Value
    FROM b2b.Customer AS customer
    CROSS APPLY (VALUES
      (N''Customer.Code'', customer.CustomerKey),
      (N''Customer.Name'', customer.Name),
      (N''Customer.PriceList'', customer.PriceListCode)
    ) AS value (FieldKey, Value)
    WHERE customer.CustomerId = @CustomerId AND NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL;

    SELECT Section, ElementName, Value FROM out.SaopAddDefault
    WHERE OrganizationId = @OrganizationId AND IsEnabled = 1 AND SourceKey = N''*'';
    RETURN;
  END;

  /*
    Cene in ceniki: po listih ''Cene'' in ''Ceniki'' preglednice Mapiranje_SAOP_API_PIM.xlsx je
    master za vsa polja SAOP. PIM zanje ne vodi zelenega stanja in ADD ne obstaja, zato tu ni
    kaj dopolnjevati. Prazen nabor je pravilen odgovor, ne manjkajoca izvedba.
  */
  SELECT ProductId = CONVERT(bigint, NULL), ItemID = @EntityKey, SourceKey = N''*'', ExistsInSaop = CONVERT(bit, 1);
  SELECT FieldKey = CONVERT(nvarchar(200), NULL), Value = CONVERT(nvarchar(max), NULL) WHERE 1 = 0;
  SELECT Section = CONVERT(nvarchar(50), NULL), ElementName = CONVERT(nvarchar(100), NULL), Value = CONVERT(nvarchar(400), NULL) WHERE 1 = 0;
END;');

/* --- Preverbe ----------------------------------------------------------- */

IF OBJECT_ID(N'out.PeekItemDocuments', N'P') IS NULL OR OBJECT_ID(N'out.GetSaopEntityValues', N'P') IS NULL
  THROW 52860, 'Suhi tek odhodne poti ni nastal.', 1;

IF OBJECT_ID(N'out.GetSaopEntityChanges', N'P') IS NULL
  THROW 52861, 'Branje cakajocih sprememb entitete ni nastalo.', 1;
