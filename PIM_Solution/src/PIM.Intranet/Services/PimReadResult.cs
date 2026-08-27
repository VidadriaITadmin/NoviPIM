using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record PimReadResult<T>(IReadOnlyList<T> Rows, long Total, string? MissingObject = null)
{
  public bool IsMissing => !string.IsNullOrWhiteSpace(MissingObject);

  public static PimReadResult<T> Missing(string objectName) => new([], 0, objectName);
}

public static class PimReadModel
{
  // SQL 2812 = procedura ne obstaja, 208 = objekt ne obstaja, 207 = stolpec ne obstaja.
  public static bool IsMissingReadModel(SqlException error) => error.Number is 2812 or 208 or 207;
}
