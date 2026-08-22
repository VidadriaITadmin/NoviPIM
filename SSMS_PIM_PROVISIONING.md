# SSMS — vzpostavitev prijave `pim_hermes`

Ta navodila izvajaj na svojem Windows računalniku v SQL Server Management Studio (SSMS). Bazi nista »moji«; gre za tvojo neprodukcijsko SQL Server instanco, ki jo aplikacija iz Docker/WSL dosega na vratih 1433.

## 1. Povezava skrbnika v SSMS

1. Odpri **SQL Server Management Studio**.
2. V oknu **Connect to Server** vpiši:
   - **Server type:** `Database Engine`
   - **Server name:** `localhost,1433`
   - **Authentication:** `SQL Server Authentication` oziroma način, s katerim se ti sicer administrativno povezuješ na to instanco.
   - **Login:** tvoja obstoječa skrbniška SQL prijava (mora imeti `sysadmin` ali pravice za `CREATE LOGIN` in `CREATE DATABASE`).
   - **Password:** geslo te obstoječe skrbniške prijave.
   - **Connect to database:** `master`
3. Klikni **Connect**.

`host.docker.internal,1433` je naslov, ki ga uporablja Docker/WSL aplikacija za dostop do Windows gostitelja. Za SSMS, ki teče neposredno na istem Windows računalniku, uporabi `localhost,1433`.

Če povezava na `localhost,1433` ne uspe, ne ugibaj z imenom instance: v SSMS odpri svoj že delujoči strežnik in preveri, katera instanca posluša na vratih 1433. Nato uporabljaj to isto instanco.

## 2. Ustvari prijavo, pravice in bazo

1. V Object Explorerju izberi povezani strežnik → **New Query**.
2. Spodnji SQL prilepi v novo poizvedbo.
3. V prvi vrstici nastavi `@PimHermesPassword` na geslo, ki je že lokalno shranjeno v `PIM_Solution/appsettings.Local.json` pod `ConnectionStrings:Pim` oziroma `ConnectionStrings:PimTest`.
   - Gesla ne zapisuj v to datoteko navodil, Git, poročila ali komentirano SQL skripto.
4. Izberi **Execute** (F5).

```sql
USE [master];
GO

DECLARE @PimHermesPassword nvarchar(128) = N'PASTE_GESLO_IZ_LOKALNE_KONFIGURACIJE_TUKAJ';
DECLARE @Sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'pim_hermes')
BEGIN
  SET @Sql = N'CREATE LOGIN [pim_hermes] WITH PASSWORD = '
    + QUOTENAME(@PimHermesPassword, '''')
    + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
  EXEC (@Sql);
END
ELSE
BEGIN
  SET @Sql = N'ALTER LOGIN [pim_hermes] WITH PASSWORD = '
    + QUOTENAME(@PimHermesPassword, '''')
    + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
  EXEC (@Sql);
END;
GO

IF DB_ID(N'PIM_test') IS NULL
  THROW 51000, 'Baza PIM_test ne obstaja na tej instanci.', 1;

IF DB_ID(N'PIM') IS NULL
  CREATE DATABASE [PIM];
GO

USE [PIM_test];
GO

IF DATABASE_PRINCIPAL_ID(N'pim_hermes') IS NULL
  CREATE USER [pim_hermes] FOR LOGIN [pim_hermes];

IF IS_ROLEMEMBER(N'db_owner', N'pim_hermes') = 1
  ALTER ROLE [db_owner] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_datawriter', N'pim_hermes') = 1
  ALTER ROLE [db_datawriter] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_ddladmin', N'pim_hermes') = 1
  ALTER ROLE [db_ddladmin] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_securityadmin', N'pim_hermes') = 1
  ALTER ROLE [db_securityadmin] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_accessadmin', N'pim_hermes') = 1
  ALTER ROLE [db_accessadmin] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_backupoperator', N'pim_hermes') = 1
  ALTER ROLE [db_backupoperator] DROP MEMBER [pim_hermes];
IF IS_ROLEMEMBER(N'db_datareader', N'pim_hermes') <> 1
  ALTER ROLE [db_datareader] ADD MEMBER [pim_hermes];
GO

USE [PIM];
GO

IF DATABASE_PRINCIPAL_ID(N'pim_hermes') IS NULL
  CREATE USER [pim_hermes] FOR LOGIN [pim_hermes];
IF IS_ROLEMEMBER(N'db_owner', N'pim_hermes') <> 1
  ALTER ROLE [db_owner] ADD MEMBER [pim_hermes];
GO

USE [master];
GO

SELECT
  loginInfo.name AS LoginName,
  loginInfo.is_disabled AS IsDisabled,
  DB_ID(N'PIM_test') AS PimTestDatabaseId,
  DB_ID(N'PIM') AS PimDatabaseId
FROM sys.sql_logins AS loginInfo
WHERE loginInfo.name = N'pim_hermes';
GO
```

Pri uspehu zadnji `SELECT` vrne eno vrstico za `pim_hermes`, `IsDisabled = 0` in neprazna ID-ja obeh baz.

## 3. Preizkus aplikacijske prijave v SSMS

Odklopi se in ustvari novo povezavo:

- **Server name:** `localhost,1433`
- **Authentication:** `SQL Server Authentication`
- **Login:** `pim_hermes`
- **Password:** isto lokalno geslo iz `PIM_Solution/appsettings.Local.json`

Preizkusi posebej obe bazi:

```sql
USE [PIM_test];
SELECT DB_NAME() AS DatabaseName, USER_NAME() AS DatabaseUser;
GO

USE [PIM];
SELECT DB_NAME() AS DatabaseName, USER_NAME() AS DatabaseUser;
GO
```

V `PIM_test` ne izvajaj `INSERT`, `UPDATE`, `DELETE`, DDL ali aplikacijskih migracij. Ta korak mora ostati samo bralen.

## 4. Nato

Ko je skripta uspešna, napiši samo »SSMS urejeno«. Nadaljeval bom z migracijami `PIM`, dvojnim migracijskim zagonom, `--verify`, bralnim izvozom fixture iz `PIM_test`, realnim F3 integracijskim tokom in dopolnitvijo `TEST_REPORT_F3.md`.

## Če je geslo prijave `sa` pozabljeno

Gesla prijave `sa` ni mogoče prebrati ali pridobiti iz SQL Serverja: SQL Server hrani le enosmerno zgoščeno vrednost. Tudi iz te kode ali dokumentacije ga ni mogoče varno obnoviti.

Če imaš drugo skrbniško prijavo ali se lahko na instanco povežeš prek Windows Authentication kot SQL Server `sysadmin`, odpri novo poizvedbo v `master` in **nastavi novo** geslo (ne zapisuj ga v Git ali v to dokumentacijo):

```sql
ALTER LOGIN [sa] ENABLE;
ALTER LOGIN [sa] WITH PASSWORD = N'NOVO_MOCNO_LOKALNO_GESLO';
GO
```

Nato se s prijavo `sa` poveži v SSMS na `localhost,1433` in nadaljuj od 2. koraka tega dokumenta. Če nimaš nobene druge skrbniške povezave, je potreben dostop do Windows strežnika oziroma postopek obnovitve administratorskega dostopa, ki ga izvede skrbnik SQL Server instance.
