using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Interop;
namespace CopyBridge;
// Explicit test-only CLI, never enabled by the normal app. Paths stay in the isolated fixture root.
static class Fixture {
    sealed record Command(string Operation,string? Path,string Result,string? ExpectedSha256);
    static string Safe(string p) {string full=System.IO.Path.GetFullPath(p);if(!full.StartsWith(@"C:\Users\Public\CopyBridge\fixtures\",StringComparison.OrdinalIgnoreCase))throw new Fault("FIXTURE_PATH_REQUIRED");return full;}
    internal static int Run(string commandPath) {
        Command c=JsonSerializer.Deserialize<Command>(File.ReadAllText(Safe(commandPath)),Bridge.Json)!;
        string result=Safe(c.Result);
        try {
            using var owner=new HwndSource(new HwndSourceParameters("CopyBridgeFixture"){Width=0,Height=0,WindowStyle=0});NativeClipboard.Owner=owner.Handle;
            if(c.Operation=="diagnose") {File.WriteAllText(result,JsonSerializer.Serialize(NativeClipboard.Diagnose(),Bridge.Json));}
            else if(c.Operation=="probe-publish") {
                string id=Guid.NewGuid().ToString();var trace=new Dictionary<string,uint>();
                var formats=NativeClipboard.Prepare("text",Safe(c.Path!),id);
                bool published=NativeClipboard.Publish(formats,()=>{},out uint sequence,trace);
                bool own=NativeClipboard.TryOwnSequence(id,out uint current,out _);
                File.WriteAllText(result,JsonSerializer.Serialize(new{status=published&&own?"PASS":"FAIL",trace,publishedSequence=sequence,currentSequence=current,ownMarkerMatches=own,sessionId=System.Diagnostics.Process.GetCurrentProcess().SessionId},Bridge.Json));
            }
            else if(c.Operation.StartsWith("copy-")) {
                string path=Safe(c.Path!);string kind=c.Operation switch{"copy-text"=>"text","copy-image"=>"image","copy-file"=>"file",_=>throw new Fault("UNKNOWN_FIXTURE_OPERATION")};
                var formats=NativeClipboard.Prepare(kind,path,Guid.NewGuid().ToString());bool done=false;
                for(int i=0;i<20&&!done;i++){done=NativeClipboard.Publish(formats,()=>{},out _);if(!done)Thread.Sleep(100);}
                if(!done)throw new Fault("CLIPBOARD_BUSY");
                File.WriteAllText(result,JsonSerializer.Serialize(new{status="PASS",operation=c.Operation,sequence=NativeClipboard.GetClipboardSequenceNumber(),sessionId=System.Diagnostics.Process.GetCurrentProcess().SessionId},Bridge.Json));
            } else if(c.Operation=="inspect") {
                if(c.ExpectedSha256 is null)throw new Fault("EXPECTED_FIXTURE_HASH_REQUIRED");
                var snapshot=NativeClipboard.Capture();string hash;long size;
                if(snapshot.Source is string source) {string full=System.IO.Path.GetFullPath(source);string received=System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"CopyBridge Received")+"\\";
                    if(!full.StartsWith(received,StringComparison.OrdinalIgnoreCase))Safe(full);
                    using var file=File.OpenRead(full);hash=Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();size=file.Length;
                }else{hash=Convert.ToHexString(SHA256.HashData(snapshot.Bytes!)).ToLowerInvariant();size=snapshot.Bytes!.Length;}
                File.WriteAllText(result,JsonSerializer.Serialize(new{status=hash==c.ExpectedSha256?"PASS":"FAIL",kind=snapshot.Kind,sizeBytes=size,sha256=hash,expectedSha256=c.ExpectedSha256,sequence=NativeClipboard.GetClipboardSequenceNumber(),sessionId=System.Diagnostics.Process.GetCurrentProcess().SessionId},Bridge.Json));
            }else throw new Fault("UNKNOWN_FIXTURE_OPERATION");
            return 0;
        }catch(Exception e){File.WriteAllText(result,JsonSerializer.Serialize(new{status="FAIL",error=e is Fault?e.Message:e.GetType().Name},Bridge.Json));return 1;}
    }
}
