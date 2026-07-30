using PIM.Intranet.Services;

const string password = "ne-sledi-se-v-produkciji";
var hash = PasswordHasher.Hash(password);
if (!PasswordHasher.Verify(password, hash)) throw new InvalidOperationException("Pravilno geslo mora biti sprejeto.");
if (PasswordHasher.Verify("napačno", hash)) throw new InvalidOperationException("Napačno geslo ne sme biti sprejeto.");
if (PasswordHasher.Verify(password, "neveljaven-zapis")) throw new InvalidOperationException("Poškodovan hash ne sme biti sprejet.");
Console.WriteLine("F4 preverjanje lokalnega gesla je uspešno.");
