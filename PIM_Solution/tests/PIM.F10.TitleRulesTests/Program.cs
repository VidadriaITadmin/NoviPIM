using PIM.Intranet.Services;

// ─── Build: prazen seznam, en blok, vec blokov z vsemi vrstami modifikatorjev ─────────────

Assert(TitleTemplateBuilder.Build(Array.Empty<TitleBlock>()) == "", "Prazen seznam blokov mora dati prazno predlogo.");

Assert(TitleTemplateBuilder.Build([new TitleBlock("ErpName")]) == "{ErpName}",
  "En blok brez argumenta in modifikatorjev.");

Assert(TitleTemplateBuilder.Build([new TitleBlock("Category", "2")]) == "{Category:2}",
  "Blok z argumentom osnove (raven kategorije).");

var fullToken = new TitleBlock("Attr", "Nazivna moč",
[
  new TitleModifier("unit", "W"),
  new TitleModifier("omitIf", "integr"),
  new TitleModifier("years"),
  new TitleModifier("lower"),
]);
Assert(TitleTemplateBuilder.Build([fullToken]) == "{Attr:Nazivna moč|unit:W|omitIf:integr|years|lower}",
  "Vec modifikatorjev, nekateri brez argumenta, se sestavijo v pravilnem vrstnem redu.");

var multiBlock = TitleTemplateBuilder.Build(
[
  new TitleBlock("ErpName"),
  new TitleBlock("Category", "2"),
  new TitleBlock("Attr", "Nazivna moč", [new TitleModifier("unit", "W")]),
  new TitleBlock("Attr", "Garancija", [new TitleModifier("years")]),
]);
Assert(multiBlock == "{ErpName} {Category:2} {Attr:Nazivna moč|unit:W} {Attr:Garancija|years}",
  "Vec blokov se zdruzi z enim presledkom, tocno kot v obstojecih pravilih.");

// ─── TryParse: povratni krog (build → parse → enak seznam) ────────────────────────────────

RoundTrip([new TitleBlock("ErpName")]);
RoundTrip([new TitleBlock("Category", "2")]);
RoundTrip([fullToken]);
RoundTrip(
[
  new TitleBlock("ErpName"),
  new TitleBlock("Manufacturer"),
  new TitleBlock("Attr", "Prevladujoča barva", [new TitleModifier("lower")]),
  new TitleBlock("Attr", "Garancija", [new TitleModifier("years")]),
  new TitleBlock("Attr", "Vrsta svetlobnega vira",
  [
    new TitleModifier("omitIfAttr", "Tip~integr"),
    new TitleModifier("onlyIfAttr", "Tip~LED"),
  ]),
]);

// ─── TryParse na resnicni predlogi SVETILA_SPLOSNO (migracija 149) ────────────────────────
// Dokaz realne zdruzljivosti: ce se ta predloga ne razclani strukturirano, izbirnik na
// /pravila/nazivi ne bi mogel odpreti ze obstojecega pravila.

const string SvetilaSplosno =
  "{ErpName} {Category:2} {Attr:Vrsta svetlobnega vira|omitIf:integr|omitIf:vgraj} " +
  "{Attr:Nazivna moč|unit:W} {Attr:Temperatura barve|unit:K} {Attr:Prevladujoča barva|lower}";

Expect(TitleTemplateBuilder.TryParse(SvetilaSplosno, out var svetilaBlocks),
  "Vzorcno pravilo SVETILA_SPLOSNO se mora razclaniti strukturirano.");
Expect(svetilaBlocks.Count == 6, $"SVETILA_SPLOSNO ima 6 zetonov, razclanjenih je {svetilaBlocks.Count}.");
Expect(svetilaBlocks[2].Kind == "Attr" && svetilaBlocks[2].Arg == "Vrsta svetlobnega vira"
  && svetilaBlocks[2].Modifiers.Count == 2, "Tretji zeton ima dva omitIf modifikatorja.");
Expect(TitleTemplateBuilder.Build(svetilaBlocks) == SvetilaSplosno,
  "Ponovna sestava razclanjenih blokov mora dati bit-za-bit enako predlogo.");

// ─── TryParse zavrne dobesedno besedilo med zetoni (sprozilec za "Napredno") ──────────────

Expect(!TitleTemplateBuilder.TryParse("{ErpName} - {Category}", out _),
  "Dobesedno besedilo med zetoni ni strukturirano predstavljivo in mora vrniti false.");
Expect(!TitleTemplateBuilder.TryParse("uvod {ErpName}", out _),
  "Dobesedno besedilo pred prvim zetonom mora vrniti false.");
Expect(!TitleTemplateBuilder.TryParse("{ErpName} zakljucek", out _),
  "Dobesedno besedilo za zadnjim zetonom mora vrniti false.");
Expect(!TitleTemplateBuilder.TryParse("", out _), "Prazna predloga ni veljavno pravilo.");
Expect(!TitleTemplateBuilder.TryParse(null, out _), "Manjkajoca predloga ni veljavno pravilo.");
Expect(!TitleTemplateBuilder.TryParse("brez zetonov", out _), "Predloga brez {...} ni strukturirano predstavljiva.");

Console.WriteLine("F10 title rules PASS.");

void RoundTrip(IReadOnlyList<TitleBlock> blocks)
{
  var template = TitleTemplateBuilder.Build(blocks);
  Expect(TitleTemplateBuilder.TryParse(template, out var parsed), $"Predloga '{template}' bi se morala razclaniti.");
  Expect(parsed.Count == blocks.Count, $"Stevilo blokov po razclembi se ne ujema za '{template}'.");
  for (var i = 0; i < blocks.Count; i++)
  {
    Expect(parsed[i].Kind == blocks[i].Kind && parsed[i].Arg == blocks[i].Arg,
      $"Osnova bloka {i} se po povratnem krogu ne ujema za '{template}'.");
    Expect(parsed[i].Modifiers.SequenceEqual(blocks[i].Modifiers),
      $"Modifikatorji bloka {i} se po povratnem krogu ne ujemajo za '{template}'.");
  }
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static void Expect(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
