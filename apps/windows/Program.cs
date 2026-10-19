using System.IO;
using System.Diagnostics;
using System.Net;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Forms=System.Windows.Forms;

namespace CopyBridge;
sealed record PairRequest(string DeviceId,string Token);
sealed record HelloRequest(int ProtocolVersion,string DeviceId,string SourceSessionId,string HandshakeId,long LastIssuedSourceSeq);
sealed record PauseRequest(bool Paused);
sealed class Identity {
    public string DeviceId {get;set;}=Guid.NewGuid().ToString();
    public string? Token {get;set;}
    public string? Peer {get;set;}
    public string Bootstrap {get;set;}=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    public DateTimeOffset Expires {get;set;}=DateTimeOffset.UtcNow.AddMinutes(10);
}
static class Program {
    internal static Identity Identity=null!;
    static string data="";
    static string bindAddress="127.0.0.1";
    static int listenPort=43861;
    static X509Certificate2 activeCertificate=null!;
    static SettingsWindow? settingsWindow;
    static string invitationCode="";
    static long lastPeerSeenTicks;
    internal static bool PeerRecentlySeen=>Interlocked.Read(ref lastPeerSeenTicks)>DateTime.UtcNow.AddSeconds(-5).Ticks;
    internal static string Origin=>$"https://{bindAddress}:{listenPort}";
    internal static bool InvitationAvailable=>Identity.Token==null&&invitationCode!=""&&Identity.Expires>DateTimeOffset.UtcNow;
    static string InvitationPath=>Path.Combine(data,"latest-invitation.copybridge");
    static Bridge bridge=null!;
    static Forms.NotifyIcon tray=null!;
    static WebApplication web=null!;
    static int pairAttempts; static DateTimeOffset pairWindow=DateTimeOffset.UtcNow;
    static bool AtCheckpoint(ref long next,long count){if(count<next)return false;next=count+4*1024*1024;return true;}
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint processId);
    static string InstanceKey(string directory)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant())))[..20];
    static void NotifyExisting(EventWaitHandle signal,string directory) {
        try {
            using var runtime=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"runtime.json")));
            if(runtime.RootElement.TryGetProperty("pid",out var value)&&value.TryGetInt32(out int pid)) {
                using var process=Process.GetProcessById(pid);
                if(string.Equals(process.MainModule?.FileName,Environment.ProcessPath,StringComparison.OrdinalIgnoreCase))AllowSetForegroundWindow((uint)pid);
            }
        }catch(Exception){/* Foreground permission is best-effort; the window is still shown by the event. */}
        signal.Set();
    }
    static readonly object metricsGate=new();
    static void Metric(object record){try{lock(metricsGate)File.AppendAllText(Path.Combine(data,"transfer-performance.jsonl"),JsonSerializer.Serialize(record,Bridge.Json)+"\n");}catch(IOException){}}
    [STAThread] public static int Main(string[] args) {
        if(args.Contains("--self-test")) {try {SelfTest(); return 0;} catch(Exception e){File.WriteAllText("self-test-failure.txt",e.ToString());return 1;}}
        string Option(string key,string fallback){int i=Array.IndexOf(args,key);return i>=0&&i+1<args.Length?args[i+1]:fallback;}
        if(args.Contains("--fixture-command"))return Fixture.Run(Option("--fixture-command",""));
        data=Path.GetFullPath(Option("--data",Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CopyBridge")));
        string instanceKey=InstanceKey(data);
        using var showSettings=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\CopyBridge-settings-"+instanceKey);
        using var single=new Mutex(true,"Local\\CopyBridge-"+instanceKey,out bool created);
        if(!created){if(args.Contains("--bootstrap"))return 2;NotifyExisting(showSettings,data);return 0;}
        if(args.Contains("--notify-existing"))return 2; // Safe secondary-launch self-test: never create a watcher.
        Directory.CreateDirectory(data);Restrict(data);
        try {
            bindAddress=PairingInvite.ChooseAddress(args.Contains("--bind")?Option("--bind",""):null,data);listenPort=int.Parse(Option("--port","43861"));if(listenPort<1||listenPort>65535)throw new Fault("INVALID_PORT",400);
            Identity=LoadIdentity();var cert=Certificate();activeCertificate=cert;
            File.WriteAllText(Path.Combine(data,"certificate.pem"),cert.ExportCertificatePem());
            if(Identity.Token==null){Identity.Bootstrap=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();Identity.Expires=DateTimeOffset.UtcNow.AddMinutes(10); SaveIdentity();WritePairing(cert);}
            File.WriteAllText(Path.Combine(data,"fingerprint.json"),JsonSerializer.Serialize(new{deviceId=Identity.DeviceId,certificateSha256=Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant()},Bridge.Json));
            if(args.Contains("--bootstrap"))return 0;
            var application=new System.Windows.Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
            using var owner=new HwndSource(new HwndSourceParameters("CopyBridgeClipboardOwner"){Width=0,Height=0,WindowStyle=0});NativeClipboard.Owner=owner.Handle;
            bridge=new(Dispatcher.CurrentDispatcher,data);BuildTray(application);bridge.Notify(Identity.Token==null?"等待配对":"等待 Mac 连接，请重新复制");
            var launchWait=ThreadPool.RegisterWaitForSingleObject(showSettings,(_,_)=>{if(!application.Dispatcher.HasShutdownStarted)application.Dispatcher.BeginInvoke(new Action(OpenSettings));},null,Timeout.Infinite,false);
            string bind=bindAddress;int port=listenPort;
            web=Server(bind,port,cert); _=web.StartAsync().ContinueWith(t=> {if(t.IsFaulted)bridge.UI.Invoke(()=>bridge.Notify("监听失败：请检查端口"));});
            var timer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(100)};timer.Tick+=(_,_)=>bridge.Observe();timer.Start();
            application.Exit+=(_,_)=>{launchWait.Unregister(null);timer.Stop();tray.Dispose();web.StopAsync().GetAwaiter().GetResult();};
            File.WriteAllText(Path.Combine(data,"runtime.json"),JsonSerializer.Serialize(new {pid=Environment.ProcessId,sessionId=System.Diagnostics.Process.GetCurrentProcess().SessionId,bind,port,startedAt=DateTimeOffset.UtcNow},Bridge.Json));
            if(Identity.Token==null||args.Contains("--settings"))OpenSettings();
            application.Run();return 0;
        } catch(Exception e) {File.WriteAllText(Path.Combine(data,"startup-error.txt"),e.GetType().Name+": "+e.Message);return 1;}
    }
    static void Restrict(string path) {
        var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);var sid=WindowsIdentity.GetCurrent().User!;
        acl.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(acl);
    }
    static Identity LoadIdentity() {
        string path=Path.Combine(data,"identity.dpapi");return File.Exists(path)?JsonSerializer.Deserialize<Identity>(ProtectedData.Unprotect(File.ReadAllBytes(path),null,DataProtectionScope.CurrentUser),Bridge.Json)!:new();
    }
    static void SaveIdentity(Identity? replacement=null) {
        string path=Path.Combine(data,"identity.dpapi");File.WriteAllBytes(path+".new",ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(replacement??Identity,Bridge.Json),null,DataProtectionScope.CurrentUser));File.Move(path+".new",path,true);
    }
    static X509Certificate2 Certificate() {
        string path=Path.Combine(data,"certificate.dpapi");if(File.Exists(path))return X509CertificateLoader.LoadPkcs12(ProtectedData.Unprotect(File.ReadAllBytes(path),null,DataProtectionScope.CurrentUser),null,X509KeyStorageFlags.UserKeySet|X509KeyStorageFlags.PersistKeySet);
        using var rsa=RSA.Create(3072); var req=new CertificateRequest("CN=CopyBridge-"+Identity.DeviceId,rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false,false,0,true));req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature|X509KeyUsageFlags.KeyEncipherment,true));
        req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection {new Oid("1.3.6.1.5.5.7.3.1")},false));
        var san=new SubjectAlternativeNameBuilder();san.AddIpAddress(IPAddress.Parse(bindAddress));san.AddDnsName(Environment.MachineName);req.CertificateExtensions.Add(san.Build());
        var cert=req.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5),DateTimeOffset.UtcNow.AddYears(2));
        File.WriteAllBytes(path,ProtectedData.Protect(cert.Export(X509ContentType.Pfx),null,DataProtectionScope.CurrentUser));return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx),null,X509KeyStorageFlags.UserKeySet|X509KeyStorageFlags.PersistKeySet);
    }
    static void WritePairing(X509Certificate2 cert) {
        PairingInvite.WritePrivate(Path.Combine(data,"pairing.json"),JsonSerializer.Serialize(new{token=Identity.Bootstrap,expiresAt=Identity.Expires,deviceId=Identity.DeviceId,certificateSha256=Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant()},Bridge.Json));
        invitationCode=PairingInvite.Encode(Origin,Identity,cert);PairingInvite.WritePrivate(InvitationPath,invitationCode);
    }
    static void RequireAuth(HttpContext context){string header=context.Request.Headers.Authorization.ToString();if(!header.StartsWith("Bearer ")||!Equal(Identity.Token,header[7..]))throw new Fault("AUTH_FAILED",401);Interlocked.Exchange(ref lastPeerSeenTicks,DateTime.UtcNow.Ticks);}
    static bool Equal(string? a,string? b)=>a!=null&&b!=null&&CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a),Encoding.UTF8.GetBytes(b));
    static async Task<T> Body<T>(HttpContext c) {
        if(c.Request.ContentLength>65536)throw new Fault("SIZE_LIMIT",413);
        var feature=c.Features.Get<IHttpMaxRequestBodySizeFeature>();if(feature is {IsReadOnly:false})feature.MaxRequestBodySize=65536;
        try{return await JsonSerializer.DeserializeAsync<T>(c.Request.Body,Bridge.Json,c.RequestAborted)??throw new Fault("INVALID_JSON",400);}catch(JsonException){throw new Fault("INVALID_JSON",400);}
    }
    static WebApplication Server(string bind,int port,X509Certificate2 certificate) {
        var builder=WebApplication.CreateSlimBuilder();builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k=> {k.Limits.MaxConcurrentConnections=32;k.Limits.MaxRequestBodySize=65536;k.Limits.RequestHeadersTimeout=TimeSpan.FromSeconds(15);k.Listen(IPAddress.Parse(bind),port,o=>o.UseHttps(certificate));});
        var app=builder.Build();
        app.Use(async(c,next)=> {
            try {
                if(c.Request.Path!="/v1/pair") {
                    RequireAuth(c);
                    if(c.Request.Path!="/v1/hello"&&c.Request.Path!="/v1/pause"&&c.Request.Path!="/v1/unpair"&&c.Request.Path!="/v1/settings")await bridge.OnUI(()=>{bridge.CheckEpoch(c.Request.Headers["X-Connection-Epoch"].ToString());return true;});
                }
                await next(c);
            }catch(Exception e) {
                if(c.Response.HasStarted){c.Abort();return;}
                string error=e is Fault?e.Message:e is BadHttpRequestException?"INVALID_REQUEST":e is OperationCanceledException?"TRANSFER_INTERRUPTED":"INTERNAL_ERROR";
                c.Response.StatusCode=e is Fault f?f.Status:e is BadHttpRequestException?400:500;
                await c.Response.WriteAsJsonAsync(new{error},Bridge.Json);
            }
        });
        app.MapPost("/v1/pair",async(HttpContext c)=> {
            var request=await Body<PairRequest>(c);
            return Results.Json(await bridge.OnUI(()=>{
                if(DateTimeOffset.UtcNow-pairWindow>TimeSpan.FromMinutes(1)){pairWindow=DateTimeOffset.UtcNow;pairAttempts=0;}
                if(++pairAttempts>5)throw new Fault("RATE_LIMIT",429);
                Bridge.Uuid(request.DeviceId);if(Identity.Token!=null||DateTimeOffset.UtcNow>Identity.Expires||!Equal(Identity.Bootstrap,request.Token))throw new Fault("AUTH_FAILED",401);
                var paired=new Identity{DeviceId=Identity.DeviceId,Peer=request.DeviceId,Token=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant(),Bootstrap="",Expires=Identity.Expires};
                SaveIdentity(paired);Identity=paired;invitationCode="";File.Delete(Path.Combine(data,"pairing.json"));File.Delete(InvitationPath);bridge.Notify("Mac 已配对，正在连接");
                return new{token=Identity.Token,deviceId=Identity.DeviceId};
            }),Bridge.Json);
        });
        // Explicit delegate type prevents ASP.NET binding this result-returning handler as RequestDelegate.
        app.MapGet("/v1/settings",new Func<HttpContext,Task<IResult>>(async c=>Results.Json(await bridge.OnUI(()=>{RequireAuth(c);return bridge.Settings.Current;}),Bridge.Json)));
        app.MapPost("/v1/settings",new Func<HttpContext,Task<IResult>>(async c=>{using var document=await Body<JsonDocument>(c);var change=SettingsChange.Parse(document.RootElement);return Results.Json(await bridge.OnUI(()=>{RequireAuth(c);return bridge.ApplySettings(change);}),Bridge.Json);}));
        app.MapPost("/v1/hello",async(HttpContext c)=> {var r=await Body<HelloRequest>(c);if(r.ProtocolVersion!=1)throw new Fault("PROTOCOL_UNSUPPORTED",400);if(r.DeviceId!=Identity.Peer)throw new Fault("AUTH_FAILED",401);return Results.Json(await bridge.OnUI(()=>bridge.Hello(r.SourceSessionId,r.HandshakeId,r.LastIssuedSourceSeq)),Bridge.Json);});
        app.MapGet("/v1/receiver-state",async()=>Results.Json(await bridge.OnUI(()=>bridge.State()),Bridge.Json));
        app.MapPost("/v1/head",async(HttpContext c)=> {var r=await Body<Head>(c);return Results.Json(await bridge.OnUI(()=>bridge.Announce(r)),Bridge.Json);});
        app.MapPost("/v1/offers",async(HttpContext c)=>{var r=await Body<Offer>(c);return Results.Json(await bridge.OnUI(()=>bridge.Accept(r)),Bridge.Json);});
        app.MapPut("/v1/transfers/{id}/items/f1",async(HttpContext c,string id)=> {
            var t=await bridge.OnUI(()=>{var t=bridge.Valid(id);if(t.Offer==null)throw new Fault("NOT_OFFERED");if(t.State=="Receiving")throw new Fault("TRANSFER_BUSY");if(t.State is not ("Offered" or "Ready"))throw new Fault("SUPERSEDED");if(c.Request.ContentLength!=t.Offer.Items[0].SizeBytes)throw new Fault("LENGTH_MISMATCH",400);if(t.State=="Offered")t.State="Receiving";return t;});
            var item=t.Offer!.Items[0];if(c.Request.ContentLength!=item.SizeBytes)throw new Fault("LENGTH_MISMATCH",400);
            var feature=c.Features.Get<IHttpMaxRequestBodySizeFeature>();if(feature is {IsReadOnly:false})feature.MaxRequestBodySize=item.SizeBytes;
            if(t.State=="Ready")return Results.Json(await bridge.OnUI(()=>bridge.Result(t)),Bridge.Json);
            await bridge.OnUI(()=>bridge.Valid(id));string part=t.Path+".part";
            try {
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(c.RequestAborted,t.Cancel.Token);timeout.CancelAfter(TimeSpan.FromHours(1));
                using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);long count=0,nextCheck=4*1024*1024;byte[] buffer=new byte[65536];
                var watch=Stopwatch.StartNew();int reads=0,checks=0;double readMs=0,writeMs=0,hashMs=0,checkMs=0;
                await using(var file=new FileStream(part,FileMode.Create,FileAccess.Write,FileShare.None,65536,FileOptions.Asynchronous)) {
                    while(true) {
                        using var idle=CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);idle.CancelAfter(TimeSpan.FromSeconds(60));
                        long stamp=Stopwatch.GetTimestamp();int read=await c.Request.Body.ReadAsync(buffer,idle.Token);readMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;if(read==0)break;reads++;count+=read;if(count>item.SizeBytes)throw new Fault("LENGTH_MISMATCH",400);
                        stamp=Stopwatch.GetTimestamp();hash.AppendData(buffer,0,read);hashMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;
                        stamp=Stopwatch.GetTimestamp();await file.WriteAsync(buffer.AsMemory(0,read),timeout.Token);writeMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;
                        if(AtCheckpoint(ref nextCheck,count)){stamp=Stopwatch.GetTimestamp();await bridge.OnUI(()=>bridge.Valid(id));checkMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;checks++;}
                    }
                    if(count!=item.SizeBytes)throw new Fault("LENGTH_MISMATCH",400);
                    if(Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()!=item.Sha256)throw new Fault("HASH_MISMATCH",400);
                    await file.FlushAsync(timeout.Token);
                }
                Metric(new{at=DateTimeOffset.UtcNow,transferId=id,direction="macToWindows",bytes=count,reads,checks,readMs,writeMs,hashMs,checkMs,totalMs=watch.Elapsed.TotalMilliseconds});
                if(t.Offer.Kind=="image")NativeClipboard.ValidateImage(await File.ReadAllBytesAsync(part));
                return Results.Json(await bridge.OnUI(()=>{bridge.Valid(id);File.Move(part,t.Path,true);t.State="Ready";bridge.Notify("校验完成，准备剪贴板");return bridge.Result(t);}),Bridge.Json);
            }catch(Exception error) {if(File.Exists(part))File.Delete(part);await bridge.OnUI(()=>{if(t.State=="Receiving"){t.State="Failed";t.Error=error is Fault?error.Message:"TRANSFER_INTERRUPTED";if(bridge.Current==id)bridge.Notify(t.Error);}return true;});throw;}
        });
        app.MapPost("/v1/transfers/{id}/complete",async(string id)=>Results.Json(await bridge.Complete(id),Bridge.Json));
        app.MapGet("/v1/transfers/{id}",async(string id)=>Results.Json(await bridge.OnUI(()=>{bridge.Observe();if(!bridge.Transfers.TryGetValue(id,out var t))throw new Fault("NOT_FOUND",404);return bridge.Result(t);}),Bridge.Json));
        app.MapPost("/v1/transfers/{id}/cancel",async(string id)=>Results.Json(await bridge.OnUI(()=>{if(!bridge.Transfers.TryGetValue(id,out var t))throw new Fault("NOT_FOUND",404);if(t.State!="Published"){t.State="Cancelled";t.Cancel.Cancel();}return bridge.Result(t);}),Bridge.Json));
        app.MapGet("/v1/outgoing/{id}/items/f1",async(HttpContext c,string id)=> {
            var outgoing=await bridge.OnUI(()=>{bridge.Observe();bridge.AllowOutgoing();var o=bridge.Out;if(o==null||o.TransferId!=id||o.State!="Ready")throw new Fault("SUPERSEDED");bridge.AllowOutgoing(o.Kind);return o;});
            c.Response.ContentLength=outgoing.Item!.SizeBytes;c.Response.ContentType=outgoing.Item.Mime;
            using var cancellation=CancellationTokenSource.CreateLinkedTokenSource(c.RequestAborted,outgoing.Cancel.Token);
            await using var input=new FileStream(outgoing.Path,FileMode.Open,FileAccess.Read,FileShare.Read,65536,FileOptions.Asynchronous|FileOptions.SequentialScan);
            byte[] buffer=new byte[65536];long count=0,nextCheck=0;int reads=0,checks=0;double readMs=0,writeMs=0,checkMs=0;var watch=Stopwatch.StartNew();
            while(true){
                long stamp=Stopwatch.GetTimestamp();int read=await input.ReadAsync(buffer,cancellation.Token);readMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;if(read==0)break;reads++;
                if(AtCheckpoint(ref nextCheck,count)){stamp=Stopwatch.GetTimestamp();await bridge.OnUI(()=>{bridge.CheckEpoch(c.Request.Headers["X-Connection-Epoch"].ToString());bridge.AllowOutgoing(outgoing.Kind);bridge.Observe();if(bridge.Out!=outgoing)throw new Fault("SUPERSEDED");return true;});checkMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;checks++;}
                stamp=Stopwatch.GetTimestamp();await c.Response.Body.WriteAsync(buffer.AsMemory(0,read),cancellation.Token);writeMs+=Stopwatch.GetElapsedTime(stamp).TotalMilliseconds;count+=read;
            }
            Metric(new{at=DateTimeOffset.UtcNow,transferId=id,direction="windowsToMac",bytes=count,reads,checks,readMs,writeMs,checkMs,totalMs=watch.Elapsed.TotalMilliseconds});
        });
        app.MapPost("/v1/pause",async(HttpContext c)=>{var r=await Body<PauseRequest>(c);return Results.Json(await bridge.OnUI(()=>{RequireAuth(c);bridge.Pause(r.Paused);return new{paused=bridge.Paused};}),Bridge.Json);});
        app.MapPost("/v1/unpair",new Func<HttpContext,Task<IResult>>(async c=>Results.Json(await bridge.OnUI(()=>{RequireAuth(c);DisconnectPeer();return new{unpaired=true};}),Bridge.Json)));
        return app;
    }
    internal static void GenerateInvitation() {
        if(!activeCertificate.MatchesHostname(bindAddress,false,false))throw new Fault("ADDRESS_CERTIFICATE_MISMATCH");
        var replacement=new Identity{DeviceId=Identity.DeviceId};SaveIdentity(replacement);Identity=replacement;bridge.Revoke();WritePairing(activeCertificate);bridge.Notify("邀请已准备，请在 Mac 确认连接");
    }
    internal static void DisconnectPeer(){GenerateInvitation();bridge.Notify("已断开设备，可重新配对");}
    internal static void CopyInvitation() {
        if(!InvitationAvailable)throw new Fault("INVITATION_UNAVAILABLE");
        var formats=new Dictionary<uint,byte[]> {{NativeClipboard.Marker,Encoding.UTF8.GetBytes(Guid.NewGuid().ToString()+"\0")},{NativeClipboard.Sensitive,new byte[]{1}},{NativeClipboard.ExcludeHistory,new byte[]{1}},{13,Encoding.Unicode.GetBytes(invitationCode+"\0")}};
        if(!NativeClipboard.Publish(formats,()=>{if(!InvitationAvailable)throw new Fault("INVITATION_UNAVAILABLE");},out _))throw new Fault("CLIPBOARD_BUSY");
    }
    internal static void ExportInvitation(string path){if(!InvitationAvailable)throw new Fault("INVITATION_UNAVAILABLE");PairingInvite.WritePrivate(path,invitationCode);}
    internal static void OpenReceived()=>Process.Start(new ProcessStartInfo("explorer.exe",bridge.Received){UseShellExecute=true});
    static void OpenSettings(){if(settingsWindow==null){settingsWindow=new SettingsWindow(bridge);settingsWindow.Closed+=(_,_)=>settingsWindow=null;}settingsWindow.Show();if(settingsWindow.WindowState==WindowState.Minimized)settingsWindow.WindowState=WindowState.Normal;settingsWindow.Activate();}
    static void BuildTray(System.Windows.Application application) {
        var menu=new Forms.ContextMenuStrip();menu.Items.Add("打开设置",null,(_,_)=>OpenSettings());var status=new Forms.ToolStripMenuItem(bridge.Status){Enabled=false};menu.Items.Add(status);
        var pause=new Forms.ToolStripMenuItem("暂停同步");pause.Click+=(_,_)=>{try{bridge.Pause(!bridge.Paused);}catch{Forms.MessageBox.Show("设置未能保存，请检查本机文件权限或可用空间。","CopyBridge");}};menu.Items.Add(pause);
        menu.Items.Add("打开接收文件夹",null,(_,_)=>OpenReceived());
        menu.Items.Add("连接设备",null,(_,_)=>OpenSettings());menu.Items.Add("退出",null,(_,_)=>application.Shutdown());
        tray=new Forms.NotifyIcon {Icon=System.Drawing.SystemIcons.Application,Text="CopyBridge：未连接",ContextMenuStrip=menu,Visible=true};
        tray.DoubleClick+=(_,_)=>OpenSettings();
        bridge.Changed+=()=>{pause.Text=bridge.Paused?"恢复同步":"暂停同步";status.Text=bridge.Status;tray.Text=("CopyBridge："+bridge.Status)[..Math.Min(63,("CopyBridge："+bridge.Status).Length)];try{File.WriteAllText(Path.Combine(data,"status.json"),JsonSerializer.Serialize(new{status=bridge.Status,paused=bridge.Paused,generation=bridge.Generation,sequence=bridge.Sequence,connected=bridge.Epoch!="",settingsRevision=bridge.Settings.Current.Revision,updatedAt=DateTimeOffset.UtcNow},Bridge.Json));}catch(IOException){}};
    }
    static void SingleInstanceSelfTest() {
        string directory=Path.Combine(Path.GetTempPath(),"CopyBridge-launch-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        try {
            string key=InstanceKey(directory);
            using var signal=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\CopyBridge-settings-"+key);
            using var held=new Mutex(true,"Local\\CopyBridge-"+key);
            File.WriteAllText(Path.Combine(directory,"runtime.json"),JsonSerializer.Serialize(new{pid=Environment.ProcessId}));
            Process Child(string option){var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"CopyBridge.exe")){UseShellExecute=false};start.ArgumentList.Add("--data");start.ArgumentList.Add(directory);start.ArgumentList.Add(option);return Process.Start(start)??throw new Exception("Launch probe did not start");}
            using(var child=Child("--notify-existing")){if(!signal.WaitOne(5000)||!child.WaitForExit(5000)||child.ExitCode!=0)throw new Exception("Secondary launch notification failed");}
            using(var child=Child("--bootstrap")){if(!child.WaitForExit(5000)||child.ExitCode!=2||signal.WaitOne(100))throw new Exception("Bootstrap did not refuse existing instance");}
            using var runtime=JsonDocument.Parse(File.ReadAllText(Path.Combine(directory,"runtime.json")));
            if(runtime.RootElement.GetProperty("pid").GetInt32()!=Environment.ProcessId||File.Exists(Path.Combine(directory,"identity.dpapi")))throw new Exception("Secondary launch started another instance");
        }finally{Directory.Delete(directory,true);}
    }
    static void SelfTest() {
        SettingsStore.SelfTest();PairingInvite.SelfTest();SingleInstanceSelfTest();
        void Check(bool ok){if(!ok)throw new Exception("assertion failed");}
        foreach(var name in new[]{"../a","C:\\a","NUL.txt","a:ads","a.","a/1","CON","COM¹.txt","LPT²"}) {try{Bridge.ValidateName(name);throw new Exception("accepted bad name");}catch(Fault f){Check(f.Message=="INVALID_FILENAME");}}
        Bridge.ValidateName("图片 测试.png");
        Bridge.ValidateItem("file",new("f1","普通文档.pdf","application/octet-stream",100,new string('a',64)));
        string sha=new('a',64);foreach(long size in new[]{2147483647L,2147483648L})Bridge.ValidateItem("file",new("f1","视频.mp4","video/mp4",size,sha));
        try{Bridge.ValidateItem("file",new("f1","视频.mp4","video/mp4",2147483649,sha));throw new Exception("size accepted");}catch(Fault f){Check(f.Message=="SIZE_LIMIT");}
        var legacy=NativeClipboard.ClassicDib(2,2,new byte[]{0,0,255,255,0,255,0,128,255,0,0,255,0,0,0,0});
        Check(legacy.Length==56&&BitConverter.ToInt32(legacy,8)==2&&BitConverter.ToInt16(legacy,14)==24);
        Check(legacy.AsSpan(40,8).SequenceEqual(new byte[]{255,0,0,255,255,255,0,0}));
        Check(legacy.AsSpan(48,8).SequenceEqual(new byte[]{0,0,255,127,255,127,0,0}));
        long checkpoint=4*1024*1024;int checks=0;
        for(long bytes=4096;bytes<=8*1024*1024;bytes+=4096)if(AtCheckpoint(ref checkpoint,bytes))checks++;
        Check(checks==2); // fragmented TLS reads must not repeatedly validate the same 64 KiB window.
        using(var source=new CancellationTokenSource())using(var request=new CancellationTokenSource())using(var linked=CancellationTokenSource.CreateLinkedTokenSource(source.Token,request.Token)){source.Cancel();Check(linked.IsCancellationRequested);}
        Check(Equal("test","test")&&!Equal("test","test2")&&!Equal(null,null));
        var h=JsonSerializer.Deserialize<Head>("{\"connectionEpoch\":\"e\",\"sourceSessionId\":\"s\",\"sourceSeq\":42,\"transferId\":\"t\",\"receiverGenAtCopy\":7}",Bridge.Json)!;Check(h.SourceSeq==42&&h.ReceiverGenAtCopy==7);
        File.WriteAllText("self-test-result.json",JsonSerializer.Serialize(new{status="PASS",checks=new[]{"filename-boundary","2GiB-integer-boundary","constant-time-auth","camelCase-contract","ordinary-single-files","fragmented-stream-checkpoint-bound","immediate-linked-cancellation","classic-DIB-color-bottom-up-alpha-padding","settings-atomic-revision-persistence","settings-strict-fields","private-invitation-boundaries","second-process-settings-notification","bootstrap-existing-instance-refusal"}},Bridge.Json));
    }
}
