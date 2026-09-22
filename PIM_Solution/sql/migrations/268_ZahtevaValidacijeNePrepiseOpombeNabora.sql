/*
  268 — urejanje kategorijske zahteve na strani Validacijski profili ne prepiše opombe nabora.

  266 je pri preusmeritvi v canon.SaveCategoryAttributeSet podal @Note = 'Validacijski profili';
  postopek nabora zapiše COALESCE(@Note, Note), zato bi preklop resnosti izbrisal opombo, ki jo je
  urednik nabora zapisal sam. Opomba ostane NULL (obstoječa se ohrani); kdo in od kod je spremembo
  naredil, že zapiše revizija nabora (b2b.AuditLog, ChangedBy).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @Definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.SaveFieldRequirement'));
DECLARE @Staro nvarchar(200) = N'@Actor = @ChangedBy, @Note = N''Validacijski profili'';';
DECLARE @Novo nvarchar(200) = N'@Actor = @ChangedBy, @Note = NULL; /* 267 */';

IF CHARINDEX(N'/* 267 */', @Definicija) = 0
BEGIN
  IF CHARINDEX(@Staro, @Definicija) = 0
    THROW 52670, N'267: v intranet.SaveFieldRequirement ni klica nabora iz 266.', 1;
  SET @Definicija = REPLACE(@Definicija, @Staro, @Novo);
  SET @Definicija = STUFF(@Definicija, CHARINDEX(N'CREATE', @Definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC (@Definicija);
END;

IF CHARINDEX(N'/* 267 */', OBJECT_DEFINITION(OBJECT_ID(N'intranet.SaveFieldRequirement'))) = 0
  THROW 52671, N'267: intranet.SaveFieldRequirement ni posodobljen.', 1;
