using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace CopyBridge;
static class PairingInvite {
    internal const string Prefix="COPYBRIDGE1:";
    internal static bool IsPrivate(IPAddress address) {var b=address.GetAddressBytes();return b.Length==4&&(b[0]==10||b[0]==172&&b[1]>=16&&b[1]<=31||b[0]==192&&b[1]==168||b[0]==127);}
    internal static string ChooseAddress(string? explicitAddress,string directory) {
        if(explicitAddress!=null){if(!IPAddress.TryParse(explicitAddress,out var explicitIp)||!IsPrivate(explicitIp))throw new Fault("PRIVATE_ADDRESS_REQUIRED",400);return explicitIp.ToString();}
        string config=Path.Combine(directory,"network.json");
        if(System.IO.File.Exists(config)){using var doc=JsonDocument.Parse(System.IO.File.ReadAllText(config));if(doc.RootElement.TryGetProperty("bind",out var item)&&IPAddress.TryParse(item.GetString(),out var saved)&&IsPrivate(saved))return saved.ToString();}
        var interfaces=NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up&&n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)).OrderByDescending(n=>n.GetIPProperties().GatewayAddresses.Any(g=>g.Address.AddressFamily==AddressFamily.InterNetwork));
        string selected=interfaces.SelectMany(n=>n.GetIPProperties().UnicastAddresses).Select(a=>a.Address).FirstOrDefault(a=>a.AddressFamily==AddressFamily.InterNetwork&&IsPrivate(a)&&!IPAddress.IsLoopback(a))?.ToString()??"127.0.0.1";
        System.IO.File.WriteAllText(config,JsonSerializer.Serialize(new{bind=selected},Bridge.Json));return selected;
    }
    internal static string Encode(string origin,Identity identity,X509Certificate2 certificate) {
        if(!Uri.TryCreate(origin,UriKind.Absolute,out var uri)||uri.Scheme!="https"||uri.UserInfo!=""||uri.Query!=""||uri.Fragment!=""||uri.AbsolutePath!="/"||!IPAddress.TryParse(uri.Host,out var ip)||!IsPrivate(ip)||!System.Text.RegularExpressions.Regex.IsMatch(origin,@"^https://[0-9.]+:[0-9]{1,5}$"))throw new Fault("INVALID_PAIRING_ADDRESS",400);
        if(!certificate.MatchesHostname(uri.Host,false,false))throw new Fault("ADDRESS_CERTIFICATE_MISMATCH");
        if(identity.Token!=null||identity.Expires<=DateTimeOffset.UtcNow||identity.Expires>DateTimeOffset.UtcNow.AddMinutes(10)||!System.Text.RegularExpressions.Regex.IsMatch(identity.Bootstrap,"^[a-f0-9]{64}$"))throw new Fault("INVITATION_UNAVAILABLE");
        byte[] json=JsonSerializer.SerializeToUtf8Bytes(new{version=1,url=origin,deviceId=identity.DeviceId,deviceName=Environment.MachineName,certificatePem=certificate.ExportCertificatePem(),certificateSha256=Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant(),token=identity.Bootstrap,expiresAt=identity.Expires},Bridge.Json);
        if(json.Length>12288)throw new Fault("SIZE_LIMIT");string code=Prefix+Convert.ToBase64String(json).TrimEnd('=').Replace('+','-').Replace('/','_');if(Encoding.UTF8.GetByteCount(code)>16384)throw new Fault("SIZE_LIMIT");return code;
    }
    internal static void WritePrivate(string path,string text) {
        var security=new FileSecurity();security.SetAccessRuleProtection(true,false);security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!,FileSystemRights.FullControl,AccessControlType.Allow));
        string full=Path.GetFullPath(path),temporary=Path.Combine(Path.GetDirectoryName(full)!,".copybridge-"+Guid.NewGuid().ToString("N")+".tmp");
        try{using(var file=new FileInfo(temporary).Create(FileMode.CreateNew,FileSystemRights.FullControl,FileShare.None,4096,FileOptions.None,security)){using var writer=new StreamWriter(file,new UTF8Encoding(false),4096,true);writer.Write(text);writer.Flush();file.Flush(true);}System.IO.File.Move(temporary,full,true);}
        finally{if(System.IO.File.Exists(temporary))System.IO.File.Delete(temporary);}
    }
    internal static void SelfTest() {
        if(!IsPrivate(IPAddress.Parse("192.168.1.100"))||!IsPrivate(IPAddress.Loopback)||IsPrivate(IPAddress.Parse("8.8.8.8"))||IsPrivate(IPAddress.IPv6Loopback))throw new Exception("Private address self-test failed");
        using var rsa=RSA.Create(2048);var request=new CertificateRequest("CN=CopyBridge test",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);var san=new SubjectAlternativeNameBuilder();san.AddIpAddress(IPAddress.Loopback);request.CertificateExtensions.Add(san.Build());using var cert=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1),DateTimeOffset.UtcNow.AddMinutes(20));
        var identity=new Identity();string code=Encode("https://127.0.0.1:43862",identity,cert);if(!code.StartsWith(Prefix)||code.Length>16384)throw new Exception("Invitation self-test failed");
        foreach(string address in new[]{"https://8.8.8.8:443","https://127.0.0.1:43862/path","http://127.0.0.1:43862","https://user@127.0.0.1:43862","https://192.168.0.1:43862"})try{Encode(address,identity,cert);throw new Exception("Invalid invitation address accepted");}catch(Fault){}
        string folder=Path.Combine(Path.GetTempPath(),"CopyBridge-invite-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
        try{string path=Path.Combine(folder,"invite.copybridge");System.IO.File.WriteAllText(path,"old test data");var wide=new FileInfo(path).GetAccessControl();wide.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid,null),FileSystemRights.Read,AccessControlType.Allow));new FileInfo(path).SetAccessControl(wide);WritePrivate(path,code);var acl=new FileInfo(path).GetAccessControl();var rules=acl.GetAccessRules(true,true,typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>();if(!acl.AreAccessRulesProtected||rules.Any(r=>!r.IdentityReference.Equals(WindowsIdentity.GetCurrent().User))||System.IO.File.ReadAllText(path)!=code)throw new Exception("Private invite ACL self-test failed");}finally{Directory.Delete(folder,true);}
        identity.Expires=DateTimeOffset.UtcNow.AddMinutes(-1);try{Encode("https://127.0.0.1:43862",identity,cert);throw new Exception("Expired invitation accepted");}catch(Fault){}
    }
}
