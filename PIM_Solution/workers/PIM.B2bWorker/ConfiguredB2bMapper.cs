using System.Text.Json;
using System.Collections.ObjectModel;

namespace PIM.B2bWorker;

public sealed record B2bFieldMapping(string SourceField, string TargetField, bool IsRequired);
public sealed record MappingRejection(string SourceField, string ReasonCode, string Detail);
public sealed record B2bMappingResult(string EntityType, string RawPayload, IReadOnlyDictionary<string, string?> Values, IReadOnlyList<MappingRejection> Rejections)
{
  public bool IsAccepted => Rejections.Count == 0;
}

public sealed class ConfiguredB2bMapper
{
  public B2bMappingResult Map(string entityType, string rawPayload, IEnumerable<B2bFieldMapping> configuration)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(entityType);
    ArgumentNullException.ThrowIfNull(configuration);
    var mappings = configuration.ToArray();
    if (mappings.Any(mapping => string.IsNullOrWhiteSpace(mapping.SourceField) || string.IsNullOrWhiteSpace(mapping.TargetField)))
      throw new ArgumentException("Preslikava mora določati izvorno in ciljno polje.", nameof(configuration));
    if (mappings.GroupBy(mapping => mapping.SourceField, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
      throw new ArgumentException("Izvorno polje ima lahko samo eno aktivno preslikavo.", nameof(configuration));
    if (mappings.GroupBy(mapping => mapping.TargetField, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
      throw new ArgumentException("Ciljno polje ima lahko samo eno aktivno preslikavo.", nameof(configuration));
    using var document = JsonDocument.Parse(rawPayload);
    if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("B2B zapis mora biti JSON objekt.");
    var properties = document.RootElement.EnumerateObject().ToArray();
    if (properties.GroupBy(property => property.Name, StringComparer.OrdinalIgnoreCase).Any(group => group.Count() > 1))
      throw new InvalidDataException("B2B zapis ne sme vsebovati podvojenih imen polj.");
    var source = properties.ToDictionary(property => property.Name, property => ScalarValue(property.Value), StringComparer.OrdinalIgnoreCase);
    var values = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
    var rejections = new List<MappingRejection>();
    foreach (var mapping in mappings)
    {
      source.TryGetValue(mapping.SourceField, out var value);
      if (mapping.IsRequired && string.IsNullOrWhiteSpace(value)) rejections.Add(new(mapping.SourceField, "MissingRequiredField", $"Manjka obvezno polje {mapping.SourceField}."));
      if (!string.IsNullOrWhiteSpace(value)) values[mapping.TargetField] = value;
    }
    foreach (var field in source.Keys.Where(field => mappings.All(mapping => !string.Equals(mapping.SourceField, field, StringComparison.OrdinalIgnoreCase))))
      rejections.Add(new(field, "UnmappedField", $"Polje {field} nima aktivne preslikave."));
    return new(entityType, rawPayload, new ReadOnlyDictionary<string, string?>(values), rejections.AsReadOnly());
  }

  private static string? ScalarValue(JsonElement value) => value.ValueKind switch
  {
    JsonValueKind.String => value.GetString(),
    JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => value.GetRawText(),
    JsonValueKind.Null => null,
    _ => throw new InvalidDataException("Preslikati je mogoče samo skalarna JSON polja.")
  };
}
