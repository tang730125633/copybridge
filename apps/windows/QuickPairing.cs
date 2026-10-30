using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CopyBridge;
sealed record QuickEnvelope(int Version,string Sealed);
static class QuickPairing {
    const string Alphabet="ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const string Context="CopyBridge quick pairing v1";
    internal static string NewCode()=>new(RandomNumberGenerator.GetBytes(20).Select(b=>Alphabet[b&31]).ToArray());
    internal static string FromBootstrap(string bootstrap)=>new(SHA256.HashData(Encoding.UTF8.GetBytes(Context+" bootstrap\n"+bootstrap)).Take(20).Select(b=>Alphabet[b&31]).ToArray());
    internal static string Display(string code)=>string.Join("-",Enumerable.Range(0,5).Select(i=>code.Substring(i*4,4)));
    internal static string Normalize(string code){var text=new string(code.ToUpperInvariant().Where(c=>c!='-'&&!char.IsWhiteSpace(c)).ToArray());if(text.Length!=20||text.Any(c=>!Alphabet.Contains(c)))throw new Fault("QUICK_CODE_INVALID",400);return text;}
    static byte[] Key(string code)=>SHA256.HashData(Encoding.UTF8.GetBytes(Context+"\n"+Normalize(code)));
    internal static QuickEnvelope Seal(string invitation,string code) {
        byte[] plain=Encoding.UTF8.GetBytes(invitation),nonce=RandomNumberGenerator.GetBytes(12),cipher=new byte[plain.Length],tag=new byte[16];
        using var aes=new AesGcm(Key(code),16);aes.Encrypt(nonce,plain,cipher,tag,Encoding.UTF8.GetBytes(Context));
        return new(1,Convert.ToBase64String(nonce.Concat(cipher).Concat(tag).ToArray()));
    }
    internal static string Open(QuickEnvelope packet,string code) {
        byte[] bytes=Convert.FromBase64String(packet.Sealed);if(packet.Version!=1||bytes.Length<28||bytes.Length>16412)throw new Fault("QUICK_PACKET_INVALID");
        byte[] plain=new byte[bytes.Length-28];using var aes=new AesGcm(Key(code),16);aes.Decrypt(bytes.AsSpan(0,12),bytes.AsSpan(12,plain.Length),bytes.AsSpan(bytes.Length-16),plain,Encoding.UTF8.GetBytes(Context));return Encoding.UTF8.GetString(plain);
    }
    internal static void SelfTest() {
        string code=NewCode(),message=new('x',12000);var packet=Seal(message,code);
        if(Normalize(Display(code).ToLowerInvariant())!=code||Open(packet,code)!=message)throw new Exception("Quick pair round-trip failed");
        try{Open(packet,NewCode());throw new Exception("Wrong code accepted");}catch(AuthenticationTagMismatchException){}
        byte[] changed=Convert.FromBase64String(packet.Sealed);changed[20]^=1;
        try{Open(new(1,Convert.ToBase64String(changed)),code);throw new Exception("Tampering accepted");}catch(AuthenticationTagMismatchException){}
        foreach(string bad in new[]{"123456","",new string('A',21),new string('O',20)})try{Normalize(bad);throw new Exception("Invalid code accepted");}catch(Fault){}
        using var rsa=RSA.Create(2048);
        var request=new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=CopyBridge synthetic test",rsa,HashAlgorithmName.SHA256,System.Security.Cryptography.RSASignaturePadding.Pkcs1);
        var san=new System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder();san.AddIpAddress(System.Net.IPAddress.Loopback);request.CertificateExtensions.Add(san.Build());
        using var cert=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1),DateTimeOffset.UtcNow.AddMinutes(20));
        string invitation=PairingInvite.Encode("https://127.0.0.1:43863",new Identity(),cert);
        System.IO.File.WriteAllText("quick-pair-test-fixture.json",JsonSerializer.Serialize(new{address="127.0.0.1:43863",code,packet=Seal(invitation,code),invitation},Bridge.Json));
    }
}
