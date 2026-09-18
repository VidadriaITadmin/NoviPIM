/*
  Priporočilo za instanco SQL Server (ni del migracije 218; odločitev skrbnika, potrebuje sysadmin).

  Analiza 2026-09-17: "cost threshold for parallelism" je bil na privzetih 5. Vsaka poizvedba z
  oceno stroška nad 5 se razdeli na vzporedne niti (MAXDOP 4); pri desetih sočasnih uporabnikih so
  bila čakanja CXPACKET + CXCONSUMER daleč največja (5.991 s + 2.686 s od zagona instance).
  Vrednost 50 pusti vzporednost velikim poizvedbam (validacija, izvozi), majhne (strani) pa tečejo na
  eni niti in si ne kradejo jeder. Sprememba velja takoj, brez ponovnega zagona; vrnitev: vrednost 5.

  Pred zagonom preveri, da si na pravi instanci: SELECT @@SERVERNAME;
*/
EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure N'cost threshold for parallelism', 50;
RECONFIGURE;
SELECT name, value_in_use FROM sys.configurations WHERE name IN (N'cost threshold for parallelism', N'max degree of parallelism');
