using System.Text;

namespace PIM.Intranet.Services;

/// <summary>Sestavni del naziva (osnova + modifikatorji), en {...} zeton iz pim.ComposeTitle.</summary>
public sealed record TitleModifier(string Kind, string? Arg)
{
  public TitleModifier(string kind) : this(kind, null) { }
}

public sealed record TitleBlock(string Kind, string? Arg, IReadOnlyList<TitleModifier> Modifiers)
{
  public TitleBlock(string kind, string? arg = null) : this(kind, arg, Array.Empty<TitleModifier>()) { }
}

/// <summary>
/// Pretvarja med strukturiranim seznamom sestavnih delov naziva (kar uporabnik sestavlja z izbirnikom
/// na /pravila/nazivi) in besedilno predlogo, ki jo bere pim.ComposeTitle (migracija 149). Predloga
/// je oblike "{Kind[:Arg]|mod[:arg]|mod[:arg]} {Kind2...}", zetoni loceni s presledki. Cist razred,
/// brez baze — round-trip mora ostati zvest obstojecemu SQL parserju.
/// </summary>
public static class TitleTemplateBuilder
{
  public static string Build(IReadOnlyList<TitleBlock> blocks) =>
    blocks.Count == 0 ? string.Empty : string.Join(" ", blocks.Select(BuildToken));

  static string BuildToken(TitleBlock block)
  {
    var text = new StringBuilder();
    text.Append('{').Append(block.Kind);
    if (!string.IsNullOrEmpty(block.Arg)) text.Append(':').Append(block.Arg);
    foreach (var modifier in block.Modifiers)
    {
      text.Append('|').Append(modifier.Kind);
      if (!string.IsNullOrEmpty(modifier.Arg)) text.Append(':').Append(modifier.Arg);
    }
    return text.Append('}').ToString();
  }

  /// <summary>
  /// Uspe samo, ce je predloga zaporedje {...} zetonov, locenih zgolj s presledki (natanko to obliko
  /// tvori Build in natanko to obliko uporabljajo vsa danasnja pravila). Rocno urejena predloga z
  /// dobesednim besedilom med zetoni (npr. "-", "test") se strukturirano ne da predstaviti — takrat
  /// vrne false, da jo stran odpre v nacinu "Napredno" namesto da podatke tiho pokvari.
  /// </summary>
  public static bool TryParse(string? template, out IReadOnlyList<TitleBlock> blocks)
  {
    blocks = Array.Empty<TitleBlock>();
    if (string.IsNullOrWhiteSpace(template)) return false;

    var result = new List<TitleBlock>();
    var position = 0;
    while (position < template.Length)
    {
      var open = template.IndexOf('{', position);
      if (open < 0)
      {
        if (!string.IsNullOrWhiteSpace(template[position..])) return false;
        break;
      }
      if (!string.IsNullOrWhiteSpace(template[position..open])) return false;

      var close = template.IndexOf('}', open);
      if (close < 0) return false;

      if (!TryParseToken(template[(open + 1)..close], out var block)) return false;
      result.Add(block);
      position = close + 1;
    }

    if (result.Count == 0) return false;
    blocks = result;
    return true;
  }

  static bool TryParseToken(string token, out TitleBlock block)
  {
    block = null!;
    if (token.Length == 0) return false;

    var parts = token.Split('|');
    var (kind, arg) = SplitKindArg(parts[0]);
    if (kind.Length == 0) return false;

    var modifiers = new List<TitleModifier>();
    for (var i = 1; i < parts.Length; i++)
    {
      var (modifierKind, modifierArg) = SplitKindArg(parts[i]);
      if (modifierKind.Length == 0) return false;
      modifiers.Add(new TitleModifier(modifierKind, modifierArg));
    }

    block = new TitleBlock(kind, arg, modifiers);
    return true;
  }

  static (string Kind, string? Arg) SplitKindArg(string part)
  {
    var colon = part.IndexOf(':');
    return colon < 0 ? (part, null) : (part[..colon], part[(colon + 1)..]);
  }
}
