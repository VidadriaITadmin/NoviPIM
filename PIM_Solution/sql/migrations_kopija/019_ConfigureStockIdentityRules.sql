SET XACT_ABORT ON;

-- Forward-only F6 configuration: source identity belongs to data, not worker branches.
MERGE map.SourceConnector AS target
USING
(
  SELECT 2 OrganizationId, N'NW_STOCK' SourceCode, N'FILE' ConnectorType
  UNION ALL SELECT 2, N'BT_STOCK', N'FILE'
) AS source
ON target.OrganizationId=source.OrganizationId AND target.SourceCode=source.SourceCode
WHEN MATCHED THEN UPDATE SET ConnectorType=source.ConnectorType, IsActive=1
WHEN NOT MATCHED THEN INSERT(SourceCode,OrganizationId,ConnectorType) VALUES(source.SourceCode,source.OrganizationId,source.ConnectorType);

MERGE map.StockIdentityRule AS target
USING
(
  SELECT connector.SourceConnectorId,N'SourceItemId' SourceKeyField,N'NW.' Prefix,
    CAST(NULL AS nvarchar(20)) ReplaceOld,CAST(NULL AS nvarchar(20)) ReplaceNew,N'ItemID' MatchPriority
  FROM map.SourceConnector connector WHERE connector.OrganizationId=2 AND connector.SourceCode=N'NW_STOCK'
  UNION ALL
  SELECT connector.SourceConnectorId,N'SourceItemId',N'BA.',N'-',N'.',N'ItemID'
  FROM map.SourceConnector connector WHERE connector.OrganizationId=2 AND connector.SourceCode=N'BT_STOCK'
) AS source
ON target.SourceConnectorId=source.SourceConnectorId AND target.SourceKeyField=source.SourceKeyField
WHEN MATCHED THEN UPDATE SET Prefix=source.Prefix,ReplaceOld=source.ReplaceOld,ReplaceNew=source.ReplaceNew,MatchPriority=source.MatchPriority,IsActive=1
WHEN NOT MATCHED THEN INSERT(SourceConnectorId,SourceKeyField,Prefix,ReplaceOld,ReplaceNew,MatchPriority)
  VALUES(source.SourceConnectorId,source.SourceKeyField,source.Prefix,source.ReplaceOld,source.ReplaceNew,source.MatchPriority);
