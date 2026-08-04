/*
  Zaženi v SSMS na Windows SQL Serverju kot SQL administrator.
  Spreminjaj samo @BackupFile. Nikoli ne nastavi PIM_test.
  Mapa mora obstajati in SQL Server service account mora imeti Write pravico.
*/
USE [master];
GO

IF DB_ID(N'PIM') IS NULL
  THROW 56001, 'Baza PIM ne obstaja na izbrani SQL Server instanci.', 1;
GO

DECLARE @BackupFile nvarchar(4000) = N'C:\PIM\Backups\PIM_full_20260731.bak';
DECLARE @Sql nvarchar(max) = N'
BACKUP DATABASE [PIM]
TO DISK = N''' + REPLACE(@BackupFile, N'''', N'''''') + N'''
WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 5,
     NAME = N''PIM full backup before Windows E2E'';

RESTORE VERIFYONLY
FROM DISK = N''' + REPLACE(@BackupFile, N'''', N'''''') + N'''
WITH CHECKSUM;';

EXEC sys.sp_executesql @Sql;
GO

SELECT TOP (1)
  backupset.backup_finish_date,
  backupset.name,
  backupset.backup_size,
  backupset.compressed_backup_size,
  mediafamily.physical_device_name
FROM msdb.dbo.backupset AS backupset
INNER JOIN msdb.dbo.backupmediafamily AS mediafamily
  ON mediafamily.media_set_id = backupset.media_set_id
WHERE backupset.database_name = N'PIM'
  AND backupset.type = N'D'
ORDER BY backupset.backup_finish_date DESC;
GO
