using System.Security.Cryptography;
using System.Text;
using System.IO;

namespace CopyBridge;
sealed record FourDigitRequest(string PublicKey);
sealed record FourDigitStart(string Id,string PublicKey);
sealed class FourDigitSession {
    internal string Id="",Code="",Sealed="";
    internal DateTimeOffset Expires;
    internal bool Approved,Consumed;
    internal (string state,string sealedValue) Poll(string id,bool invitationAvailable,DateTimeOffset now) {
        bool same=CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(Id),Encoding.UTF8.GetBytes(id));
        if(Consumed||Expires<=now||!invitationAvailable||!same)throw new Fault("PAIRING_EXPIRED",409);
        if(!Approved)return ("waiting","");
        Consumed=true;return ("approved",Sealed);
    }
}
static class FourDigitPairing {
    static byte[] Digest(string label,byte[] secret,byte[] client,byte[] server)=>SHA256.HashData(Encoding.UTF8.GetBytes(label).Concat(secret).Concat(client).Concat(server).ToArray());
    internal static (string code,byte[] key) Derive(byte[] secret,byte[] client,byte[] server) {
        var hash=Digest("CopyBridge SAS v2",secret,client,server);
        uint number=System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(hash);
        return ((number%10000).ToString("D4"),Digest("CopyBridge key v2",secret,client,server));
    }
    internal static (FourDigitSession session,string publicKey) Create(string encoded,string invitation) {
        byte[] client;try {client=Convert.FromBase64String(encoded);} catch(FormatException){throw new Fault("INVALID_KEY",400);}
        if(client.Length>512)throw new Fault("INVALID_KEY",400);
        using var peer=ECDiffieHellman.Create();
        try {peer.ImportSubjectPublicKeyInfo(client,out int consumed);if(consumed!=client.Length||peer.ExportParameters(false).Curve.Oid.Value!=ECCurve.NamedCurves.nistP256.Oid.Value)throw new Fault("INVALID_KEY",400);}
        catch(CryptographicException){throw new Fault("INVALID_KEY",400);}
        using var own=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        byte[] server=own.ExportSubjectPublicKeyInfo(),secret=own.DeriveRawSecretAgreement(peer.PublicKey);
        var (code,key)=Derive(secret,client,server);CryptographicOperations.ZeroMemory(secret);
        byte[] nonce=RandomNumberGenerator.GetBytes(12),plain=Encoding.UTF8.GetBytes(invitation),cipher=new byte[plain.Length],tag=new byte[16];
        using(var aes=new AesGcm(key,16))aes.Encrypt(nonce,plain,cipher,tag,Encoding.UTF8.GetBytes("CopyBridge pairing v2"));
        CryptographicOperations.ZeroMemory(key);
        return (new FourDigitSession{Id=Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant(),Code=code,Sealed=Convert.ToBase64String(nonce.Concat(cipher).Concat(tag).ToArray()),Expires=DateTimeOffset.UtcNow.AddMinutes(2)},Convert.ToBase64String(server));
    }
    internal static void SelfTest() {
        var vector=Derive(Enumerable.Range(0,32).Select(i=>(byte)i).ToArray(),Encoding.UTF8.GetBytes("client"),Encoding.UTF8.GetBytes("server"));
        if(vector.code!="2241"||Convert.ToHexString(vector.key).ToLowerInvariant()!="96a8bf23bb72e80bf6eb4ae75e069b66106902e2c661dd62ed0113c78bf17a5f")throw new Exception("Four digit cross-platform vector failed");
        using var client=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);byte[] clientPub=client.ExportSubjectPublicKeyInfo();
        var (session,serverEncoded)=Create(Convert.ToBase64String(clientPub),"test invitation");
        if(session.Poll(session.Id,true,DateTimeOffset.UtcNow).sealedValue!="")throw new Exception("Unapproved invitation exposed");
        try{session.Poll(new string('0',32),true,DateTimeOffset.UtcNow);throw new Exception("Wrong session accepted");}catch(Fault){}
        try{session.Poll(session.Id,true,session.Expires);throw new Exception("Expired session accepted");}catch(Fault){}
        session.Approved=true;if(session.Poll(session.Id,true,DateTimeOffset.UtcNow).sealedValue!=session.Sealed)throw new Exception("Approved invitation missing");
        try{session.Poll(session.Id,true,DateTimeOffset.UtcNow);throw new Exception("Pairing replay accepted");}catch(Fault){}
        byte[] server=Convert.FromBase64String(serverEncoded);using var peer=ECDiffieHellman.Create();peer.ImportSubjectPublicKeyInfo(server,out _);
        byte[] secret=client.DeriveRawSecretAgreement(peer.PublicKey);var (code,key)=Derive(secret,clientPub,server);
        if(code!=session.Code||code.Length!=4||code.Any(c=>c<'0'||c>'9'))throw new Exception("Four digit agreement failed");
        byte[] sealedBytes=Convert.FromBase64String(session.Sealed),plain=new byte[sealedBytes.Length-28];using(var aes=new AesGcm(key,16))aes.Decrypt(sealedBytes.AsSpan(0,12),sealedBytes.AsSpan(12,plain.Length),sealedBytes.AsSpan(sealedBytes.Length-16),plain,Encoding.UTF8.GetBytes("CopyBridge pairing v2"));
        if(Encoding.UTF8.GetString(plain)!="test invitation")throw new Exception("Four digit decryption failed");
        using var impostor=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);byte[] wrong=impostor.DeriveRawSecretAgreement(peer.PublicKey);if(Derive(wrong,clientPub,server).key.SequenceEqual(key))throw new Exception("Wrong key accepted");
        sealedBytes[12]^=1;try{using var aes=new AesGcm(key,16);aes.Decrypt(sealedBytes.AsSpan(0,12),sealedBytes.AsSpan(12,plain.Length),sealedBytes.AsSpan(sealedBytes.Length-16),plain,Encoding.UTF8.GetBytes("CopyBridge pairing v2"));throw new Exception("Tampered invitation accepted");}catch(AuthenticationTagMismatchException){}
        File.WriteAllText("four-pair-test-fixture.json",System.Text.Json.JsonSerializer.Serialize(new {clientPrivate=Convert.ToBase64String(client.ExportPkcs8PrivateKey()),serverPublic=serverEncoded,code=session.Code,sealedValue=session.Sealed},Bridge.Json));
    }
}
