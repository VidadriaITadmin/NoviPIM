/*
  256 — ERP-first pot za nove artikle dobaviteljev.

  Dobaviteljev XML ustvari samo kandidat. Pravi canon.Product sme ustvariti izkljucno
  vhod iz SAOP; kandidat gre v SAOP kot POST in ostane viden, dokler SAOP ne vrne artikla.
*/
SET XACT_ABORT ON;

/* Varnostna meja: noben nov ali obstoječ ne-SAOP konektor ne sme polniti kataloga. */
UPDATE map.SourceConnector SET CanCreateProducts=0
WHERE ConnectorType<>N'SAOP' AND CanCreateProducts<>0;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'map.SourceConnector') AND name=N'CK_SourceConnector_OnlySaopCreatesProducts')
  ALTER TABLE map.SourceConnector ADD CONSTRAINT CK_SourceConnector_OnlySaopCreatesProducts
    CHECK (CanCreateProducts=0 OR ConnectorType=N'SAOP');

/* Stari PIM-first ukaz je zavestno zaprt: kandidat se ne sme več pretvoriti v canon.Product. */
EXEC(N'
CREATE OR ALTER PROCEDURE map.ImportSupplierProductCandidates
  @CandidatesJson nvarchar(max), @Actor nvarchar(200)
AS
BEGIN
  THROW 52456, N''Uvoz kandidata neposredno v PIM ni več dovoljen. Kandidata dopolni in pošlji v SAOP; PIM kartico ustvari povratni SAOP uvoz.'', 1;
END;');

/* Tudi neposredna stara odobritev je zaprta; sicer bi mimo UI znova ustvarila PIM artikel. */
EXEC(N'
CREATE OR ALTER PROCEDURE map.ApproveSupplierProductCandidate
  @SupplierProductCandidateId bigint, @Actor nvarchar(200)
AS
BEGIN
  THROW 52460, N''Kandidata ni dovoljeno odobriti neposredno v PIM. Najprej ga pošlji v SAOP; PIM kartico ustvari povratni SAOP uvoz.'', 1;
END;');
/* Isti trije rezultatni nabori kot out.GetSaopItemWriteState, vendar podatki iz XML kandidata. */
EXEC(N'
CREATE OR ALTER PROCEDURE out.GetSupplierCandidateSaopWriteState
  @OrganizationId int, @SupplierProductCandidateId bigint
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @InboxId bigint, @RecordOrdinal int, @ItemID nvarchar(200), @SourceKey nvarchar(50);
  SELECT @InboxId=candidate.InboxId, @RecordOrdinal=candidate.RecordOrdinal, @ItemID=candidate.ItemID,
    @SourceKey=N''*''
  FROM map.SupplierProductCandidate candidate
  WHERE candidate.SupplierProductCandidateId=@SupplierProductCandidateId
    AND candidate.OrganizationId=@OrganizationId AND candidate.Status=N''PENDING'' AND candidate.IsActive=1;

  IF @InboxId IS NULL THROW 52457, N''Kandidat ne obstaja, je zavrnjen ali ne čaka več na ERP.'', 1;
  SET @SourceKey=CASE WHEN CHARINDEX(N''.'',@ItemID)>1 THEN UPPER(LEFT(@ItemID,CHARINDEX(N''.'',@ItemID)-1)) ELSE N''*'' END;

  SELECT ProductId=CONVERT(bigint,NULL), ItemID=@ItemID, SourceKey=@SourceKey, ExistsInSaop=CONVERT(bit,0);

  ;WITH vrednost AS
  (
    SELECT value.TargetFieldCode FieldKey, CONVERT(nvarchar(4000),value.Value) Value,
      ROW_NUMBER() OVER(PARTITION BY value.TargetFieldCode ORDER BY value.ValueOrdinal DESC, value.ExtractedValueId DESC) Mesto
    FROM map.ExtractedValue value
    INNER JOIN out.SaopXmlField field ON field.TargetKind=N''SAOP_PRODUCT'' AND field.IsEnabled=1 AND field.FieldKey=value.TargetFieldCode
    WHERE value.InboxId=@InboxId AND value.RecordOrdinal=@RecordOrdinal
      AND NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000),value.Value))),N'''') IS NOT NULL
  )
  SELECT FieldKey, Value FROM vrednost WHERE Mesto=1;

  SELECT Section, ElementName, Value
  FROM out.SaopAddDefault
  WHERE OrganizationId=@OrganizationId AND IsEnabled=1 AND SourceKey IN(N''*'',@SourceKey)
  ORDER BY CASE WHEN SourceKey=N''*'' THEN 1 ELSE 0 END,Section,ElementName;
END;');

/* Kandidat je v vseh stanjih poti še kandidat; povezava s ProductId nastane šele pri SAOP uvozu. */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSupplierProductCandidates
  @OrganizationId int=NULL, @SourceCode nvarchar(100)=NULL, @Status nvarchar(20)=NULL,
  @Search nvarchar(200)=NULL, @Skip int=0, @Take int=50, @SaopState nvarchar(20)=NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),N'''');
  SET @SaopState=NULLIF(LTRIM(RTRIM(@SaopState)),N'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE N''%''+@Search+N''%'' END;

  SELECT candidate.SupplierProductCandidateId,candidate.OrganizationId,organization.Name OrganizationName,
    candidate.SourceCode,candidate.ItemID,candidate.EAN,candidate.Status,candidate.IsActive,
    candidate.FirstSeenUtc,candidate.LastSeenUtc,candidate.OccurrenceCount,candidate.DecidedUtc,
    candidate.DecidedBy,candidate.DecisionReason,candidate.CreatedProductId,candidate.ItemIdFromEan,
    inbox.RunId,inbox.EntityType,product.ItemID ProductItemId,product.ErpExistence,
    SupplierTitle=(SELECT TOP(1) CONVERT(nvarchar(400),value.Value) FROM map.ExtractedValue value
      WHERE value.InboxId=candidate.InboxId AND value.RecordOrdinal=candidate.RecordOrdinal
        AND value.TargetFieldCode LIKE N''ProductText.%TITLE%'' AND NULLIF(LTRIM(RTRIM(value.Value)),N'''') IS NOT NULL
      ORDER BY CASE WHEN value.TargetFieldCode LIKE N''%.sl'' THEN 0 ELSE 1 END)
  INTO #Base
  FROM map.SupplierProductCandidate candidate
  INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=candidate.OrganizationId
  INNER JOIN raw.Inbox inbox ON inbox.InboxId=candidate.InboxId
  LEFT JOIN canon.Product product ON product.ProductId=candidate.CreatedProductId
  WHERE (@OrganizationId IS NULL OR candidate.OrganizationId=@OrganizationId)
    AND (@SourceCode IS NULL OR candidate.SourceCode=@SourceCode)
    AND (@Status IS NULL OR candidate.Status=@Status)
    AND (@Like IS NULL OR candidate.ItemID LIKE @Like OR candidate.EAN LIKE @Like OR product.ItemID LIKE @Like);

  SELECT base.SupplierProductCandidateId,
    Live=SUM(CASE WHEN message.Status IN(N''PendingApproval'',N''Pending'',N''Retry'',N''Sending'') THEN 1 ELSE 0 END),
    PendingApproval=SUM(CASE WHEN message.Status=N''PendingApproval'' THEN 1 ELSE 0 END),
    LastMessageId=MAX(message.OutboxMessageId),LastUpdatedUtc=MAX(message.UpdatedUtc)
  INTO #Queue
  FROM #Base base
  INNER JOIN out.OutboxMessage message ON message.OrganizationId=base.OrganizationId
    AND message.TargetKind=N''SAOP_PRODUCT'' AND message.EntityType=N''Product''
    AND message.EntityKey IN(base.ItemID,base.ProductItemId)
  GROUP BY base.SupplierProductCandidateId;

  SELECT base.*,SaopLiveMessages=ISNULL(queue.Live,0),SaopPendingApproval=ISNULL(queue.PendingApproval,0),
    SaopLastStatus=lastMessage.Status,SaopLastBatchId=lastMessage.OutboundBatchId,
    SaopLastUpdatedUtc=queue.LastUpdatedUtc,SaopLastError=lastMessage.LastError,
    SaopState=CASE
      WHEN base.Status=N''REJECTED'' THEN NULL
      WHEN base.ErpExistence=N''CONFIRMED_IN_ERP'' THEN N''CONFIRMED''
      WHEN ISNULL(queue.Live,0)>0 THEN N''QUEUED''
      WHEN lastMessage.Status IN(N''Dead'',N''Error'',N''Drift'') THEN N''FAILED''
      WHEN lastMessage.Status IN(N''Sent'',N''Verified'') THEN N''SENT''
      ELSE N''NOT_QUEUED'' END,
    SaopAssignedItemId=(SELECT TOP(1) assignment.AssignedSaopItemId FROM out.SaopItemAssignment assignment
      INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=assignment.OutboxMessageId
      WHERE message.OrganizationId=base.OrganizationId AND message.TargetKind=N''SAOP_PRODUCT''
        AND message.EntityType=N''Product'' AND message.EntityKey IN(base.ItemID,base.ProductItemId)
      ORDER BY assignment.OutboxMessageId DESC)
  INTO #Rows
  FROM #Base base LEFT JOIN #Queue queue ON queue.SupplierProductCandidateId=base.SupplierProductCandidateId
  LEFT JOIN out.OutboxMessage lastMessage ON lastMessage.OutboxMessageId=queue.LastMessageId;

  IF @SaopState IS NOT NULL DELETE #Rows WHERE ISNULL(SaopState,N'''')<>@SaopState;
  SELECT * INTO #Page FROM #Rows ORDER BY CASE Status WHEN N''PENDING'' THEN 0 ELSE 1 END,LastSeenUtc DESC,SupplierProductCandidateId DESC
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
  SELECT * FROM #Page ORDER BY CASE Status WHEN N''PENDING'' THEN 0 ELSE 1 END,LastSeenUtc DESC,SupplierProductCandidateId DESC;
  SELECT COUNT_BIG(*) TotalCount,ISNULL(SUM(CASE WHEN Status=N''PENDING'' THEN 1 ELSE 0 END),0) PendingCount,
    ISNULL(SUM(CASE WHEN Status=N''APPROVED'' THEN 1 ELSE 0 END),0) ApprovedCount,
    ISNULL(SUM(CASE WHEN Status=N''REJECTED'' THEN 1 ELSE 0 END),0) RejectedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''NOT_QUEUED'' THEN 1 ELSE 0 END),0) ImportedWaitingCount,
    ISNULL(SUM(CASE WHEN SaopState=N''QUEUED'' THEN 1 ELSE 0 END),0) QueuedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''SENT'' THEN 1 ELSE 0 END),0) SentCount,
    ISNULL(SUM(CASE WHEN SaopState=N''FAILED'' THEN 1 ELSE 0 END),0) FailedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''CONFIRMED'' THEN 1 ELSE 0 END),0) ConfirmedCount
  FROM #Rows;
END;');

IF OBJECT_ID(N'out.GetSupplierCandidateSaopWriteState',N'P') IS NULL
  THROW 52458,N'256: priprava kandidata za SAOP ni nastala.',1;
IF EXISTS(SELECT 1 FROM map.SourceConnector WHERE ConnectorType<>N'SAOP' AND CanCreateProducts=1)
  THROW 52459,N'256: ne-SAOP konektor sme ustvariti artikel.',1;