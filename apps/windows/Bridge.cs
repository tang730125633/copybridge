using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Threading;

namespace CopyBridge;
sealed class Fault(string code,int status=409):Exception(code) { public int Status=status; }
record Head(string ConnectionEpoch,string SourceSessionId,long SourceSeq,string TransferId,long ReceiverGenAtCopy);
record Item(string ItemId,string Name,string Mime,long SizeBytes,string Sha256);
record Offer(string ConnectionEpoch,string SourceSessionId,long SourceSeq,string TransferId,long ReceiverGenAtCopy,string Kind,Item[] Items) {
    internal Head Head=>new(ConnectionEpoch,SourceSessionId,SourceSeq,TransferId,ReceiverGenAtCopy);
}
sealed class Transfer(Head head) {
    internal readonly SemaphoreSlim CompleteGate=new(1,1);
    internal readonly CancellationTokenSource Cancel=new();
    public Head Head=head; public Offer? Offer; public string State="Announced",Error="",Path=""; public DateTimeOffset? PublishedAt; public uint PublishedSequence;
}
sealed class Outgoing(string id,long generation) {
    internal CancellationTokenSource Cancel=new();
    public string TransferId=id,State="Preparing",Kind=""; public long Generation=generation; public Item? Item; public string Path="";
    public object View()=>new {transferId=TransferId,generation=Generation,kind=Kind,item=Item,state=State};
}
sealed class Bridge {
    internal static readonly JsonSerializerOptions Json=new(JsonSerializerDefaults.Web);
    internal readonly Dispatcher UI; internal readonly string Data,Received;
    internal string Epoch="",Session="",Handshake="",Current="",Status="未连接，请配对";
    internal bool Paused; internal long Generation,HighWater,Floor; internal uint Sequence;
    internal Outgoing? Out; internal readonly Dictionary<string,Transfer> Transfers=new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string,long> sessionHigh=[];
    readonly SemaphoreSlim snapshotGate=new(1,1);
    internal event Action? Changed;
    internal Bridge(Dispatcher dispatcher,string data) {
        UI=dispatcher; Data=data; Received=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"CopyBridge Received");
        Directory.CreateDirectory(Received); Directory.CreateDirectory(Path.Combine(data,"outgoing"));
        Sequence=NativeClipboard.GetClipboardSequenceNumber();
    }
    internal Task<T> OnUI<T>(Func<T> f)=>UI.InvokeAsync(f).Task;
    internal void Notify(string s) {Status=s; try{File.AppendAllText(Path.Combine(Data,"events.jsonl"),JsonSerializer.Serialize(new{at=DateTimeOffset.UtcNow,transferId=Current,generation=Generation,sequence=Sequence,status=s},Json)+"\n");}catch(IOException){} Changed?.Invoke();}
    internal void Revoke() { foreach(var t in Transfers.Values)if(t.State is not ("Published" or "Failed" or "Cancelled")){t.State="Superseded";t.Cancel.Cancel();} Current=""; Out?.Cancel.Cancel(); Out=null; Epoch=""; Sequence=NativeClipboard.GetClipboardSequenceNumber(); }
    internal void Pause(bool paused) {Paused=paused; Revoke(); Notify(paused?"已暂停":"等待重新连接，请重新复制");}
    internal void Observe(bool snapshot=true) {
        if(NativeClipboard.SessionLocked()==true){if(Epoch!="")Revoke();const string locked="Windows 已锁定，请解锁后重新复制";if(Status!=locked)Notify(locked);return;}
        uint seq=NativeClipboard.GetClipboardSequenceNumber(); if(seq==0) {Notify("无法访问当前桌面剪贴板");return;}
        if(seq==Sequence)return;
        if(Current!=""&&Transfers.TryGetValue(Current,out var own)&&own.State=="Published"&&NativeClipboard.ClipboardOwnedByUs()) {
            if(NativeClipboard.TryOwnSequence(Current,out uint owned,out bool deferred)){Sequence=owned;own.PublishedSequence=owned;return;}
            // A temporary read lock must not turn our deferred CloseClipboard update into an outgoing echo.
            if(deferred)return;
        }
        Sequence=seq;
        if(Epoch==""||Paused)return;
        Generation++; if(Current!="" && Transfers.TryGetValue(Current,out var previous) && previous.State!="Published"){previous.State="Superseded";previous.Cancel.Cancel();}
        Current=""; Out?.Cancel.Cancel(); Out=new(Guid.NewGuid().ToString(),Generation); var outgoing=Out;
        Notify("正在准备 Windows 新复制");
        if(snapshot) UI.BeginInvoke(()=>Capture(outgoing,seq));
    }
    void Capture(Outgoing outgoing,uint seq) {
        if(Out!=outgoing||Paused||Epoch==""||NativeClipboard.GetClipboardSequenceNumber()!=seq)return;
        try {var snapshot=NativeClipboard.Capture(); if(NativeClipboard.GetClipboardSequenceNumber()!=seq){Observe();return;}
            _=BuildOutgoing(outgoing,snapshot);
        } catch(Exception e) {outgoing.State="Failed"; Notify(e is Fault?e.Message:"SOURCE_UNAVAILABLE");}
    }
    async Task BuildOutgoing(Outgoing outgoing,ClipSnapshot snapshot) {
        string dir=Path.Combine(Data,"outgoing",outgoing.TransferId);
        bool acquired=false;
        try {
            await snapshotGate.WaitAsync(outgoing.Cancel.Token); acquired=true;
            foreach(string old in Directory.EnumerateDirectories(Path.Combine(Data,"outgoing")))if(old!=dir)try{Directory.Delete(old,true);}catch(IOException){}
            long used=Directory.EnumerateFiles(Path.Combine(Data,"outgoing"),"*",SearchOption.AllDirectories).Sum(p=>new FileInfo(p).Length);
            if(used>2L*1024*1024*1024)throw new Fault("SPOOL_BUDGET");
            var item=await Task.Run(async()=> {
                ValidateName(snapshot.Name); Directory.CreateDirectory(dir);
                string path=Path.Combine(dir,snapshot.Name),part=path+".part"; long size;
                if(snapshot.Source is string source) {
                    var info=new FileInfo(source); long before=info.Length; var modified=info.LastWriteTimeUtc; if(before>2L*1024*1024*1024)throw new Fault("SIZE_LIMIT");
                    using(var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read,65536,FileOptions.Asynchronous|FileOptions.SequentialScan))
                    using(var output=new FileStream(part,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,FileOptions.Asynchronous)) await input.CopyToAsync(output,outgoing.Cancel.Token);
                    info.Refresh(); if(!info.Exists||info.Length!=before||info.LastWriteTimeUtc!=modified)throw new Fault("SOURCE_CHANGED"); size=before;
                } else {await File.WriteAllBytesAsync(part,snapshot.Bytes!);size=snapshot.Bytes!.Length;}
                File.Move(part,path); string hash; using(var f=File.OpenRead(path))hash=Convert.ToHexString(await SHA256.HashDataAsync(f,outgoing.Cancel.Token)).ToLowerInvariant();
                outgoing.Path=path; return new Item("f1",snapshot.Name,snapshot.Mime,size,hash);
            });
            await OnUI(()=> {if(Out==outgoing&&!Paused&&Epoch!=""){outgoing.Item=item;outgoing.Kind=snapshot.Kind;outgoing.State="Ready";Notify("Windows 新复制已准备，等待 Mac 接收");}return true;});
        }catch(Exception e) {try{if(Directory.Exists(dir))Directory.Delete(dir,true);}catch{} await OnUI(()=> {if(Out==outgoing){outgoing.State="Failed";Notify(e is Fault?e.Message:"SOURCE_UNAVAILABLE");}return true;});}
        finally{if(acquired)snapshotGate.Release();}
    }
    internal object Hello(string session,string handshake,long last) {
        if(NativeClipboard.SessionLocked()==true)throw new Fault("SESSION_LOCKED");
        if(Paused)throw new Fault("PAUSED"); Uuid(session);Uuid(handshake); if(last<0)throw new Fault("INVALID_SEQUENCE",400);
        if(Epoch!=""&&Session==session&&Handshake==handshake)return HelloView();
        Revoke(); Transfers.Clear(); if(!sessionHigh.ContainsKey(session)&&sessionHigh.Count>=1024)throw new Fault("SOURCE_SESSION_LIMIT"); Session=session;Handshake=handshake;HighWater=Math.Max(sessionHigh.GetValueOrDefault(session),last);Floor=HighWater;
        sessionHigh[session]=HighWater; Epoch=Guid.NewGuid().ToString(); Sequence=NativeClipboard.GetClipboardSequenceNumber();
        if(Sequence==0)throw new Fault("CLIPBOARD_ACCESS_DENIED"); Notify("已连接，双向同步；请重新复制");return HelloView();
    }
    object HelloView()=>new {connectionEpoch=Epoch,seqFloor=Floor,receiverGeneration=Generation,deviceId=Program.Identity.DeviceId,limits=new{textBytes=1048576,imageBytes=33554432,fileBytes=2147483648L},outgoing=(object?)null};
    internal void CheckEpoch(string epoch) {if(NativeClipboard.SessionLocked()==true)throw new Fault("SESSION_LOCKED");if(Paused||Epoch==""||epoch!=Epoch)throw new Fault("SESSION_REVOKED");}
    internal object State() {Observe();return new{connectionEpoch=Epoch,receiverGeneration=Generation,paused=Paused,outgoing=Out?.View(),status=Status};}
    internal object Announce(Head h) {
        CheckEpoch(h.ConnectionEpoch); if(h.SourceSessionId!=Session)throw new Fault("SESSION_REVOKED");Uuid(h.TransferId);
        if(h.SourceSeq<0||h.ReceiverGenAtCopy<0)throw new Fault("INVALID_SEQUENCE",400);
        Observe();
        if(Transfers.TryGetValue(h.TransferId,out var known)) {if(known.Head!=h)throw new Fault("IDEMPOTENCY_CONFLICT"); if(known.Error!="")throw new Fault(known.Error);return Result(known);}
        if(Transfers.Count>=10000)throw new Fault("SESSION_LIMIT");
        var t=new Transfer(h);Transfers[h.TransferId]=t;
        if(h.SourceSeq<=HighWater) {t.State="Failed";t.Error="SUPERSEDED";throw new Fault(t.Error);}
        HighWater=h.SourceSeq;sessionHigh[Session]=HighWater;
        if(Current!=""&&Transfers.TryGetValue(Current,out var old)&&old.State!="Published"){old.State="Superseded";old.Cancel.Cancel();}Current="";
        if(h.ReceiverGenAtCopy!=Generation) {t.State="Failed";t.Error="LOCAL_CLIPBOARD_CHANGED";throw new Fault(t.Error);}
        Out?.Cancel.Cancel();Out=null;Current=h.TransferId;Notify("正在准备 Mac 新复制，尚不可粘贴");return Result(t);
    }
    internal Transfer Valid(string id) {
        if(!Transfers.TryGetValue(id,out var t))throw new Fault("NOT_FOUND",404);
        CheckEpoch(t.Head.ConnectionEpoch);Observe();
        if(t.Head.ReceiverGenAtCopy!=Generation)throw new Fault("LOCAL_CLIPBOARD_CHANGED");
        if(Current!=id||t.Head.SourceSeq!=HighWater||t.State is "Failed" or "Cancelled" or "Superseded")throw new Fault("SUPERSEDED");return t;
    }
    internal object Accept(Offer offer) {
        var t=Valid(offer.TransferId); if(t.Head!=offer.Head)throw new Fault("IDEMPOTENCY_CONFLICT");
        if(t.Offer!=null) {if(JsonSerializer.Serialize(t.Offer,Json)!=JsonSerializer.Serialize(offer,Json))throw new Fault("IDEMPOTENCY_CONFLICT");return Result(t);}
        if(offer.Items?.Length!=1)throw new Fault("TYPE_UNSUPPORTED",400);ValidateItem(offer.Kind,offer.Items[0]);
        long retained=Directory.EnumerateFiles(Received,"*",SearchOption.AllDirectories).Sum(p=>new FileInfo(p).Length);
        if(retained+offer.Items[0].SizeBytes>20L*1024*1024*1024)throw new Fault("RECEIVED_BUDGET");
        var drive=new DriveInfo(Path.GetPathRoot(Received)!); if(drive.AvailableFreeSpace<offer.Items[0].SizeBytes+128*1024*1024)throw new Fault("DISK_FULL");
        string dir=Path.Combine(Received,Epoch,offer.TransferId);Directory.CreateDirectory(dir);t.Path=Path.Combine(dir,offer.Items[0].Name);t.Offer=offer;t.State="Offered";Notify("正在传输，尚不可粘贴");return Result(t);
    }
    internal async Task<object> Complete(string id) {
        var transfer=await OnUI(()=>Transfers.TryGetValue(id,out var t)?t:throw new Fault("NOT_FOUND",404));
        await transfer.CompleteGate.WaitAsync();
        try{return await CompleteCore(id);}
        catch(Exception error){await OnUI(()=>{if(transfer.State=="Ready"){transfer.State="Failed";transfer.Error=error is Fault?error.Message:"PUBLISH_FAILED";if(Current==id)Notify(transfer.Error);}return true;});throw;}
        finally{transfer.CompleteGate.Release();}
    }
    async Task<object> CompleteCore(string id) {
        var t=await OnUI(()=> {if(!Transfers.TryGetValue(id,out var x))throw new Fault("NOT_FOUND",404); if(x.State=="Published")return x; Valid(id);if(x.State!="Ready")throw new Fault("NOT_READY");return x;});
        if(t.State=="Published")return await OnUI(()=>Result(t));
        Dictionary<uint,byte[]> formats=await Task.Run(()=>NativeClipboard.Prepare(t.Offer!.Kind,t.Path,id));
        await File.WriteAllTextAsync(Path.Combine(Path.GetDirectoryName(t.Path)!,".copybridge-protected.json"),JsonSerializer.Serialize(new{transferId=id,protectedAt=DateTimeOffset.UtcNow},Json));
        for(int attempt=0;attempt<20;attempt++) {
            bool done=await OnUI(()=> {
                if(t.State=="Published")return true;
                Valid(id);
                uint publishedSequence=0;
                try{if(!NativeClipboard.Publish(formats,()=>Valid(id),out publishedSequence))return false;}
                catch{if(publishedSequence!=0)Sequence=publishedSequence;throw;}
                Sequence=publishedSequence;t.PublishedSequence=publishedSequence;t.PublishedAt=DateTimeOffset.UtcNow;t.State="Published";
                Notify(NativeClipboard.GetClipboardSequenceNumber()==publishedSequence?"可粘贴：Mac 内容已就绪":"已发布，正在确认剪贴板归属");return true;
            });
            if(done)return await OnUI(()=>Result(t));await Task.Delay(100);
        }
        throw new Fault("CLIPBOARD_BUSY");
    }
    internal object Result(Transfer t)=>new {state=t.State,publishedAt=t.PublishedAt,currentlyOnClipboard=t.State=="Published"&&NativeClipboard.GetClipboardSequenceNumber()==t.PublishedSequence,receiverGeneration=Generation,error=t.Error==""?null:t.Error};
    internal static void Uuid(string s) {if(!Guid.TryParseExact(s,"D",out _))throw new Fault("INVALID_ID",400);}
    internal static void ValidateName(string name) {
        if(string.IsNullOrWhiteSpace(name)||name.Length>180||name is "." or ".."||name.EndsWith('.')||name.EndsWith(' ')||name.Any(c=>c<32||"<>:\"/\\|?*".Contains(c))||Regex.IsMatch(name,"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\\.|$)",RegexOptions.IgnoreCase))throw new Fault("INVALID_FILENAME",400);
    }
    internal static void ValidateItem(string kind,Item i) {
        ValidateName(i.Name); if(i.ItemId!="f1"||!Regex.IsMatch(i.Sha256??"","^[a-f0-9]{64}$"))throw new Fault("INVALID_METADATA",400);
        long limit=kind switch {"text"=>1048576,"image"=>33554432,"file"=>2147483648,_=>throw new Fault("TYPE_UNSUPPORTED",400)};
        if(i.SizeBytes<0||i.SizeBytes>limit)throw new Fault("SIZE_LIMIT",413);
        if(kind=="text"&&i.Mime!="text/plain"||kind=="image"&&i.Mime!="image/png")throw new Fault("TYPE_UNSUPPORTED",400);
        if(kind=="file") {string ext=Path.GetExtension(i.Name).ToLowerInvariant();string expected=ext switch{".png"=>"image/png",".jpg" or ".jpeg"=>"image/jpeg",".mp4"=>"video/mp4",_=>"application/octet-stream"};if(i.Mime!=expected)throw new Fault("TYPE_UNSUPPORTED",400);}
    }
}
