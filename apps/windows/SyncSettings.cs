using System.IO;
using System.Text.Json;

namespace CopyBridge;
record SyncPreferences(long Revision,bool MacToWindows,bool WindowsToMac,bool Text,bool Image,bool File,bool Paused) {
    internal static SyncPreferences Defaults=>new(1,true,true,true,true,true,false);
    internal bool AllowsKind(string kind)=>kind switch{"text"=>Text,"image"=>Image,"file"=>File,_=>false};
}
record SettingsChange(long ExpectedRevision,bool MacToWindows,bool WindowsToMac,bool Text,bool Image,bool File,bool Paused) {
    internal static SettingsChange From(SyncPreferences value,bool? paused=null)=>new(value.Revision,value.MacToWindows,value.WindowsToMac,value.Text,value.Image,value.File,paused??value.Paused);
    internal static SettingsChange Parse(JsonElement json) {
        if(json.ValueKind!=JsonValueKind.Object)throw new Fault("INVALID_SETTINGS",400);
        string[] fields=["expectedRevision","macToWindows","windowsToMac","text","image","file","paused"];
        var seen=new HashSet<string>(StringComparer.Ordinal);
        foreach(var property in json.EnumerateObject())if(!fields.Contains(property.Name)||!seen.Add(property.Name))throw new Fault("INVALID_SETTINGS",400);
        if(seen.Count!=fields.Length||json.GetProperty("expectedRevision").ValueKind!=JsonValueKind.Number||!json.GetProperty("expectedRevision").TryGetInt64(out long revision)||revision<1)throw new Fault("INVALID_SETTINGS",400);
        bool Read(string key){var value=json.GetProperty(key);if(value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))throw new Fault("INVALID_SETTINGS",400);return value.GetBoolean();}
        return new(revision,Read("macToWindows"),Read("windowsToMac"),Read("text"),Read("image"),Read("file"),Read("paused"));
    }
}
sealed class SettingsStore {
    readonly string path;
    internal SyncPreferences Current {get;private set;}
    internal SettingsStore(string directory) {
        path=Path.Combine(directory,"settings.json");
        if(!System.IO.File.Exists(path)){Current=SyncPreferences.Defaults;Save(Current);return;}
        using var document=JsonDocument.Parse(System.IO.File.ReadAllText(path));
        var json=document.RootElement;
        if(json.ValueKind!=JsonValueKind.Object||!json.TryGetProperty("revision",out var revision)||revision.ValueKind!=JsonValueKind.Number||!revision.TryGetInt64(out long value)||value<1)throw new Fault("INVALID_SETTINGS_FILE",400);
        // Reuse strict complete-field validation for the persistent representation.
        var fields=json.EnumerateObject().ToDictionary(p=>p.Name=="revision"?"expectedRevision":p.Name,p=>p.Value.Clone());
        var change=SettingsChange.Parse(JsonSerializer.SerializeToElement(fields));
        Current=new(value,change.MacToWindows,change.WindowsToMac,change.Text,change.Image,change.File,change.Paused);
    }
    internal SyncPreferences Apply(SettingsChange change) {
        if(change.ExpectedRevision!=Current.Revision)throw new Fault("SETTINGS_CONFLICT");
        if(Current.Revision==long.MaxValue)throw new Fault("SETTINGS_REVISION_LIMIT");
        var next=new SyncPreferences(Current.Revision+1,change.MacToWindows,change.WindowsToMac,change.Text,change.Image,change.File,change.Paused);
        Save(next);Current=next;return next;
    }
    void Save(SyncPreferences value) {
        string temporary=path+".new-"+Guid.NewGuid().ToString("N");
        try{using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){file.Write(JsonSerializer.SerializeToUtf8Bytes(value,Bridge.Json));file.Flush(true);}System.IO.File.Move(temporary,path,true);}
        finally{if(System.IO.File.Exists(temporary))System.IO.File.Delete(temporary);}
    }
    internal static void SelfTest() {
        void Check(bool condition){if(!condition)throw new Exception("Settings self-test failed");}
        string directory=Path.Combine(Path.GetTempPath(),"CopyBridge-settings-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        try {
            var store=new SettingsStore(directory);Check(store.Current==SyncPreferences.Defaults);
            var next=store.Apply(new(1,false,true,true,false,true,true));Check(next.Revision==2&&next.Paused&&!next.MacToWindows&&!next.AllowsKind("image"));
            Check(new SettingsStore(directory).Current==next);
            try{store.Apply(SettingsChange.From(SyncPreferences.Defaults));throw new Exception("Stale revision accepted");}catch(Fault e){Check(e.Message=="SETTINGS_CONFLICT");}
            foreach(string bad in new[]{"{}","{\"expectedRevision\":1,\"macToWindows\":true}","{\"expectedRevision\":2,\"macToWindows\":true,\"windowsToMac\":true,\"text\":\"true\",\"image\":true,\"file\":true,\"paused\":false}"}){using var json=JsonDocument.Parse(bad);try{SettingsChange.Parse(json.RootElement);throw new Exception("Bad settings accepted");}catch(Fault){}}
            string saved=Path.Combine(directory,"settings.json");System.IO.File.Delete(saved);Directory.CreateDirectory(saved);
            try{store.Apply(SettingsChange.From(next,false));throw new Exception("Write failure ignored");}catch(IOException){}catch(UnauthorizedAccessException){}
            Check(store.Current==next);Directory.Delete(saved);
        }finally{Directory.Delete(directory,true);}
    }
}
