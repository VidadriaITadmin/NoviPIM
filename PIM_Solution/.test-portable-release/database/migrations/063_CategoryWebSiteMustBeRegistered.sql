/*
  063 — kategorija ne sme kazati na spletno stran, ki je v registru ni.

  Povod: v canon.ProductCategory je ostala ena vrstica s spletno stranjo 'svetila.si' (s piko)
  in potjo 'Svetila/Test'. Naredil jo je dokazni izdelek F2-PROOF-001, ki ga PIM.F2.Integration
  namenoma pusca v razvojni bazi. Koda 'svetila.si' v canon.WebSite ne obstaja — od migracije
  059 se stran imenuje 'svetila_si' — zato taka vrstica ne more nikoli priti v noben izvoz.
  Odlocitev uporabnika 2026-08-22: vrstica gre ven.

  Da se to ne ponovi, pravilo ni vec navada, ampak omejitev baze: WebSite v canon.ProductCategory
  mora biti koda iz registra canon.WebSite. Test, ki je vrstico delal, zdaj uporablja
  registrirano kodo; kdor bo pisal nov test ali nov vir, mora spletno stran najprej registrirati
  — kar je isti korak kot pri konektorju ali izvoznem profilu.

  Kar ta migracija NE naredi: pim.ProductCategory omejitve ne dobi. Objava je posnetek in sme
  za kratek cas nositi tudi to, kar je bilo v katalogu prej; brise se skupaj s svojim izvorom.
*/

SET XACT_ABORT ON;

/* --- 1) vrstice brez registrirane spletne strani ------------------------- */

DELETE objavljena
FROM pim.ProductCategory objavljena
WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite spletna WHERE spletna.WebSiteCode = objavljena.WebSite);

DELETE kategorija
FROM canon.ProductCategory kategorija
WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite spletna WHERE spletna.WebSiteCode = kategorija.WebSite);

/* --- 2) odslej to prepreci baza ------------------------------------------ */

/*
  Tuji kljuc zahteva enak tip na obeh straneh: canon.ProductCategory.WebSite je nvarchar(100),
  canon.WebSite.WebSiteCode pa je 059 ustvarila kot nvarchar(50). Sirsi je kljuc kataloga, zato
  se poravna register — enolicnost je treba za to za hip odstraniti in vrniti.
*/
IF EXISTS
(
  SELECT 1 FROM sys.columns
  WHERE object_id = OBJECT_ID(N'canon.WebSite') AND name = N'WebSiteCode' AND max_length < 200
)
BEGIN
  IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_WebSite_Code')
    ALTER TABLE canon.WebSite DROP CONSTRAINT UQ_WebSite_Code;
  ALTER TABLE canon.WebSite ALTER COLUMN WebSiteCode nvarchar(100) NOT NULL;
  ALTER TABLE canon.WebSite ADD CONSTRAINT UQ_WebSite_Code UNIQUE (WebSiteCode);
END;

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ProductCategory_WebSite')
BEGIN
  ALTER TABLE canon.ProductCategory WITH CHECK
    ADD CONSTRAINT FK_ProductCategory_WebSite FOREIGN KEY (WebSite)
    REFERENCES canon.WebSite (WebSiteCode);
END;

/* --- 3) preverbi ---------------------------------------------------------- */

IF EXISTS
(
  SELECT 1 FROM canon.ProductCategory kategorija
  WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite spletna WHERE spletna.WebSiteCode = kategorija.WebSite)
)
  THROW 52631, 'V katalogu je kategorija brez registrirane spletne strani.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ProductCategory_WebSite' AND is_not_trusted = 0)
  THROW 52632, 'Omejitev FK_ProductCategory_WebSite ne obstaja ali ni preverjena.', 1;
