using System.IO;
using DataFormats=System.Windows.DataFormats;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CopyBridge;
record ClipSnapshot(string Kind, string Name, string Mime, byte[]? Bytes, string? Source);
static class NativeClipboard
{
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll",SetLastError=true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr handle);
    [StructLayout(LayoutKind.Explicit)] struct SessionInfoHeader {
        [FieldOffset(0)] public uint Level;
        [FieldOffset(8)] public uint SessionId;
        [FieldOffset(12)] public int State;
        [FieldOffset(16)] public int Flags;
    }
    [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSQuerySessionInformation(IntPtr server,int session,int infoClass,out IntPtr buffer,out uint bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    internal static bool? SessionLocked() {
        if(!WTSQuerySessionInformation(IntPtr.Zero,System.Diagnostics.Process.GetCurrentProcess().SessionId,25,out var p,out uint bytes))return null;
        try{if(bytes<20)return null;var info=Marshal.PtrToStructure<SessionInfoHeader>(p);if(info.Level!=1||info.SessionId!=System.Diagnostics.Process.GetCurrentProcess().SessionId)return null;return info.Flags switch{0=>true,1=>false,_=>null};}finally{WTSFreeMemory(p);}
    }
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int index,IntPtr info,uint length,out uint needed);
    static object WindowInfo(IntPtr hwnd) {GetWindowThreadProcessId(hwnd,out uint pid);string name="",session="";try{var p=System.Diagnostics.Process.GetProcessById((int)pid);name=p.ProcessName;session=p.SessionId.ToString();}catch{}return new{window=hwnd.ToInt64(),pid,name,session};}
    static string DesktopName(IntPtr h) {if(h==IntPtr.Zero)return "unavailable";var p=Marshal.AllocHGlobal(1024);try{return GetUserObjectInformation(h,2,p,1024,out _)?Marshal.PtrToStringUni(p)??"":"error:"+Marshal.GetLastWin32Error();}finally{Marshal.FreeHGlobal(p);}}
    internal static object Diagnose() {
        var openBefore=WindowInfo(GetOpenClipboardWindow());var ownerBefore=WindowInfo(GetClipboardOwner());
        bool opened=OpenClipboard(Owner);int openError=opened?0:Marshal.GetLastWin32Error();if(opened)CloseClipboard();
        bool nullOpened=OpenClipboard(IntPtr.Zero);int nullError=nullOpened?0:Marshal.GetLastWin32Error();if(nullOpened)CloseClipboard();
        var input=OpenInputDesktop(0,false,1);int inputError=input==IntPtr.Zero?Marshal.GetLastWin32Error():0;string inputName=DesktopName(input);if(input!=IntPtr.Zero)CloseDesktop(input);
        return new{status="DIAGNOSTIC",at=DateTimeOffset.UtcNow,sessionId=System.Diagnostics.Process.GetCurrentProcess().SessionId,sequence=GetClipboardSequenceNumber(),openBefore,ownerBefore,opened,openError,nullOpened,nullError,sessionLocked=SessionLocked(),ownerWindow=Owner.ToInt64(),ownerWindowValid=IsWindow(Owner),windowStation=DesktopName(GetProcessWindowStation()),threadDesktop=DesktopName(GetThreadDesktop(GetCurrentThreadId())),inputDesktop=inputName,inputError};
    }
    internal static bool ClipboardOwnedByUs()=>Owner!=IntPtr.Zero&&GetClipboardOwner()==Owner;
    internal static bool TryOwnSequence(string id,out uint sequence,out bool deferred) {
        sequence=0;deferred=false;if(!ClipboardOwnedByUs())return false;if(!OpenClipboard(Owner)){deferred=true;return false;}
        bool matched=false;uint inside=0;
        try {
            if(!ClipboardOwnedByUs())return false;
            inside=GetClipboardSequenceNumber();var handle=GetClipboardData(Marker);
            if(handle==IntPtr.Zero)return false;ulong size=GlobalSize(handle).ToUInt64();if(size==0||size>128)return false;
            var p=GlobalLock(handle);if(p==IntPtr.Zero)return false;
            try{var bytes=new byte[(int)size];Marshal.Copy(p,bytes,0,bytes.Length);matched=Encoding.UTF8.GetString(bytes).TrimEnd('\0')==id&&GetClipboardSequenceNumber()==inside;}finally{GlobalUnlock(handle);}
        }finally{CloseClipboard();}
        if(!matched||!ClipboardOwnedByUs()||GetClipboardSequenceNumber()!=inside)return false;
        sequence=inside;return true;
    }
    internal static readonly uint Png = RegisterClipboardFormat("PNG");
    internal static readonly uint Marker = RegisterClipboardFormat("CopyBridge.v1");
    internal static IntPtr Owner;
    internal static ClipSnapshot Capture()
    {
        var d=System.Windows.Clipboard.GetDataObject() ?? throw new Fault("TYPE_UNSUPPORTED");
        if (d.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing") || d.GetDataPresent("CanIncludeInClipboardHistory") && d.GetData("CanIncludeInClipboardHistory") is MemoryStream m && m.ToArray().All(b=>b==0)) throw new Fault("SENSITIVE_SOURCE");
        if(d.GetDataPresent(DataFormats.FileDrop)) {
            var files=d.GetData(DataFormats.FileDrop) as string[];
            if(files?.Length!=1) throw new Fault("TYPE_UNSUPPORTED");
            var f=new FileInfo(files[0]);
            if(!f.Exists || (f.Attributes&(FileAttributes.ReparsePoint|FileAttributes.Offline|FileAttributes.Directory))!=0) throw new Fault("SOURCE_UNAVAILABLE");
            string mime=Path.GetExtension(f.Name).ToLowerInvariant() switch {".png"=>"image/png", ".jpg" or ".jpeg"=>"image/jpeg", ".mp4"=>"video/mp4", _=>"application/octet-stream"};
            return new("file",f.Name,mime,null,f.FullName);
        }
        if(d.GetDataPresent("PNG") && d.GetData("PNG") is Stream png) {
            if(png.Length>32*1024*1024) throw new Fault("SIZE_LIMIT");
            using var ms=new MemoryStream(); png.Position=0; png.CopyTo(ms);
            var bytes=ms.ToArray(); ValidateImage(bytes); return new("image","clipboard.png","image/png",bytes,null);
        }
        if(System.Windows.Clipboard.ContainsImage()) {
            var bmp=System.Windows.Clipboard.GetImage() ?? throw new Fault("TYPE_UNSUPPORTED");
            CheckPixels(bmp.PixelWidth,bmp.PixelHeight);
            var encoder=new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bmp));
            using var ms=new MemoryStream(); encoder.Save(ms);
            if(ms.Length>32*1024*1024)throw new Fault("SIZE_LIMIT");
            return new("image","clipboard.png","image/png",ms.ToArray(),null);
        }
        if(d.GetDataPresent(DataFormats.UnicodeText)) {
            var value=d.GetData(DataFormats.UnicodeText) as string ?? "";
            byte[] bytes=Encoding.UTF8.GetBytes(value);
            if(bytes.Length>1024*1024)throw new Fault("SIZE_LIMIT");
            return new("text","clipboard.txt","text/plain",bytes,null);
        }
        throw new Fault("TYPE_UNSUPPORTED");
    }
    internal static void CheckPixels(int w,int h) { if(w<=0 || h<=0 || (long)w*h>32_000_000)throw new Fault("SIZE_LIMIT"); }
    internal static BitmapSource ValidateImage(byte[] bytes) {
        using var ms=new MemoryStream(bytes);
        if(bytes.Length>32*1024*1024)throw new Fault("SIZE_LIMIT");
        var decoder=BitmapDecoder.Create(ms,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.None);
        var header=decoder.Frames[0]; CheckPixels(header.PixelWidth,header.PixelHeight);
        ms.Position=0; var frame=BitmapDecoder.Create(ms,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames[0]; frame.Freeze(); return frame;
    }
    internal static Dictionary<uint,byte[]> Prepare(string kind,string path,string id) {
        var data=new Dictionary<uint,byte[]> {{Marker,Encoding.UTF8.GetBytes(id+"\0")}};
        if(kind=="text") {
            var text=new UTF8Encoding(false,true).GetString(File.ReadAllBytes(path));
            if(text.Contains('\0')) throw new Fault("TYPE_UNSUPPORTED");
            data[13]=Encoding.Unicode.GetBytes(text.Replace("\r\n","\n").Replace("\r","\n").Replace("\n","\r\n")+"\0");
        } else if(kind=="file") {
            byte[] names=Encoding.Unicode.GetBytes(path+"\0\0"); byte[] drop=new byte[20+names.Length];
            BitConverter.GetBytes(20).CopyTo(drop,0); BitConverter.GetBytes(1).CopyTo(drop,16); names.CopyTo(drop,20); data[15]=drop;
            if(Path.GetExtension(path).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg") {
                if(new FileInfo(path).Length<=32*1024*1024)try{AddImage(data,ReadImage(path));}catch(Fault e) when(e.Message=="SIZE_LIMIT"){}
            }
        } else AddImage(data,ReadImage(path));
        return data;
    }
    static byte[] ReadImage(string path) {if(new FileInfo(path).Length>32*1024*1024)throw new Fault("SIZE_LIMIT");return File.ReadAllBytes(path);}
    static void AddImage(Dictionary<uint,byte[]> data,byte[] image) {
        var frame=ValidateImage(image);
        var converted=new FormatConvertedBitmap(frame,PixelFormats.Bgra32,null,0); converted.Freeze();
        int width=converted.PixelWidth,height=converted.PixelHeight,stride=checked(width*4);
        var dib=new byte[checked(124+stride*height)];
        using(var writer=new BinaryWriter(new MemoryStream(dib))) {
            writer.Write(124); writer.Write(width); writer.Write(-height); writer.Write((short)1); writer.Write((short)32);
            writer.Write(3); writer.Write(stride*height); writer.Seek(40,SeekOrigin.Begin);
            writer.Write(0x00ff0000); writer.Write(0x0000ff00); writer.Write(0x000000ff); writer.Write(unchecked((int)0xff000000));
            writer.Write(0x73524742); // LCS_sRGB
        }
        var pixels=new byte[stride*height]; converted.CopyPixels(pixels,stride,0); pixels.CopyTo(dib,124);
        using var ms=new MemoryStream(); var encoder=new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(frame)); encoder.Save(ms); data[Png]=ms.ToArray();
        // Legacy OLE consumers get an explicit opaque bitmap; PNG and V5 still retain alpha.
        data[8]=ClassicDib(width,height,pixels);data[17]=dib;
    }
    internal static byte[] ClassicDib(int width,int height,byte[] bgra) {
        CheckPixels(width,height);if(bgra.Length!=checked(width*height*4))throw new Fault("INVALID_IMAGE");
        int stride=checked((width*3+3)&~3);var result=new byte[checked(40+stride*height)];
        using(var writer=new BinaryWriter(new MemoryStream(result))) {
            writer.Write(40);writer.Write(width);writer.Write(height);writer.Write((short)1);writer.Write((short)24);writer.Write(0);writer.Write(stride*height);
        }
        for(int y=0;y<height;y++)for(int x=0;x<width;x++) {
            int source=(y*width+x)*4,target=40+(height-1-y)*stride+x*3,alpha=bgra[source+3];
            for(int channel=0;channel<3;channel++)result[target+channel]=(byte)((bgra[source+channel]*alpha+255*(255-alpha)+127)/255);
        }
        return result;
    }
    // Memory ownership transfers only after each successful SetClipboardData.
    internal static bool Publish(Dictionary<uint,byte[]> data,Action validate,out uint publishedSequence,Dictionary<string,uint>? trace=null) {
        publishedSequence=0;
        if(SessionLocked()==true)throw new Fault("SESSION_LOCKED");
        var allocations=new Dictionary<uint,IntPtr>();
        try {
            foreach(var entry in data) {
                var h=GlobalAlloc(0x0042,(UIntPtr)entry.Value.Length); if(h==IntPtr.Zero)throw new Fault("PUBLISH_FAILED");
                allocations.Add(entry.Key,h); var p=GlobalLock(h); if(p==IntPtr.Zero)throw new Fault("PUBLISH_FAILED");
                Marshal.Copy(entry.Value,0,p,entry.Value.Length); GlobalUnlock(h);
            }
            if(trace!=null)trace["beforeOpen"]=GetClipboardSequenceNumber();
            if(!OpenClipboard(Owner))return false;
            if(trace!=null)trace["afterOpen"]=GetClipboardSequenceNumber();
            bool emptied=false;
            try { validate(); if(!EmptyClipboard())throw new Fault("PUBLISH_FAILED");emptied=true;
                foreach(var entry in allocations.ToArray()) { if(SetClipboardData(entry.Key,entry.Value)==IntPtr.Zero)throw new Fault("PUBLISH_FAILED"); allocations.Remove(entry.Key); }
            } finally {
                if(emptied)publishedSequence=GetClipboardSequenceNumber();if(trace!=null)trace["beforeClose"]=GetClipboardSequenceNumber();CloseClipboard();
                if(trace!=null)trace["afterClose"]=GetClipboardSequenceNumber();
                // Windows finalizes additional sequence changes on CloseClipboard, including partial publish failures.
                if(emptied){string marker=Encoding.UTF8.GetString(data[Marker]).TrimEnd('\0');if(TryOwnSequence(marker,out uint finalSequence,out _))publishedSequence=finalSequence;}
                if(trace!=null)trace["verifiedOwnSequence"]=publishedSequence;
            }
            return true;
        } finally {foreach(var h in allocations.Values)GlobalFree(h);}
    }
}
