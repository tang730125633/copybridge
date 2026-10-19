using System.Windows;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Threading;
using C=System.Windows.Controls;
using Button=System.Windows.Controls.Button;
using CheckBox=System.Windows.Controls.CheckBox;
using TextBlock=System.Windows.Controls.TextBlock;
using Brush=System.Windows.Media.Brush;
using Color=System.Windows.Media.Color;

namespace CopyBridge;
sealed class SettingsWindow:System.Windows.Window {
    readonly Bridge bridge;
    readonly TextBlock connection=new(),peer=new(),invitation=new(),inviteFeedback=new(),feedback=new();
    readonly Button copy=new(),export=new();
    readonly CheckBox toWindows=new(),toMac=new(),text=new(),image=new(),file=new(),paused=new();
    readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromSeconds(1)};
    long loadedRevision=-1;bool dirty,loading;
    static readonly Brush Ink=new SolidColorBrush(Color.FromRgb(36,41,39));
    static readonly Brush Muted=new SolidColorBrush(Color.FromRgb(99,108,104));
    internal SettingsWindow(Bridge value) {
        bridge=value;Title="CopyBridge 设置";Width=800;Height=700;MinWidth=660;MinHeight=560;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Background=new SolidColorBrush(Color.FromRgb(249,248,244));Foreground=Ink;FontFamily=new System.Windows.Media.FontFamily("Microsoft YaHei UI");FontSize=14;UseLayoutRounding=true;
        var root=new C.DockPanel{Margin=new Thickness(28)};
        var heading=new C.StackPanel();heading.Children.Add(Label("CopyBridge",30,FontWeights.SemiBold));heading.Children.Add(Label("两台电脑，直接复制粘贴",15,null,Muted));C.DockPanel.SetDock(heading,C.Dock.Top);root.Children.Add(heading);
        var tabs=new C.TabControl{Margin=new Thickness(0,22,0,0),Background=Background,BorderBrush=new SolidColorBrush(Color.FromRgb(218,221,215))};
        tabs.Items.Add(new C.TabItem{Header="连接设备",Content=ConnectionPage()});tabs.Items.Add(new C.TabItem{Header="同步设置",Content=PreferencesPage()});tabs.Items.Add(new C.TabItem{Header="工作原理",Content=ExplanationPage()});root.Children.Add(tabs);Content=root;
        bridge.Changed+=Refresh;timer.Tick+=(_,_)=>Refresh();timer.Start();Closed+=(_,_)=>{timer.Stop();bridge.Changed-=Refresh;};Refresh();
    }
    static TextBlock Label(string value,double size=14,FontWeight? weight=null,Brush? color=null)=>new(){Text=value,FontSize=size,FontWeight=weight??FontWeights.Normal,Foreground=color??Ink,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,10)};
    static C.ScrollViewer Scroll(C.StackPanel content)=>new(){Content=content,VerticalScrollBarVisibility=C.ScrollBarVisibility.Auto,Padding=new Thickness(22)};
    static Button Action(string label,Action action){var b=new Button{Content=label,Padding=new Thickness(16,8,16,8),Margin=new Thickness(0,0,10,10),MinHeight=38};b.Click+=(_,_)=>action();return b;}
    void Safely(Action action){try{action();}catch(Exception e){System.Windows.MessageBox.Show(Explain(e),"CopyBridge",MessageBoxButton.OK,MessageBoxImage.Information);}}
    static string Explain(Exception e)=>e is Fault f?f.Message switch{"SETTINGS_CONFLICT"=>"设置已在另一台电脑上更新。请先重新载入，再保存。","CLIPBOARD_BUSY"=>"剪贴板正忙，请稍后重试。","SESSION_LOCKED"=>"请先解锁 Windows，再继续。","INVITATION_UNAVAILABLE"=>"邀请已过期或已被使用，请重新生成。","ADDRESS_CERTIFICATE_MISMATCH"=>"当前网络地址与设备证书不一致，暂时不能生成邀请。请恢复原来的启动地址后重试。",_=>"这次操作未完成，请稍后重试（"+f.Message+"）。"}:"无法保存或完成操作，请检查本机可用空间与文件权限。";
    C.ScrollViewer ConnectionPage() {
        var p=new C.StackPanel();p.Children.Add(Label("连接你的 Mac",23,FontWeights.SemiBold));
        connection.FontSize=16;connection.Margin=new Thickness(0,0,0,18);connection.TextWrapping=TextWrapping.Wrap;p.Children.Add(connection);
        p.Children.Add(Label("本机  ·  "+Environment.MachineName,16,FontWeights.SemiBold));peer.Foreground=Muted;peer.Margin=new Thickness(0,0,0,18);p.Children.Add(peer);
        p.Children.Add(Label("当前连接地址",14,FontWeights.SemiBold));var address=new C.TextBox{Text=Program.Origin,IsReadOnly=true,Padding=new Thickness(10),Margin=new Thickness(0,0,0,10)};AutomationProperties.SetName(address,"当前局域网连接地址");p.Children.Add(address);
        p.Children.Add(Label(Program.Origin.Contains("127.0.0.1")?"当前为本机测试地址，另一台电脑无法直接访问。正常启动会优先选择可用的局域网地址。":"让 Mac 与这台电脑处于同一 Wi-Fi 或可互通的局域网。",13,null,Muted));
        p.Children.Add(Action("连接 Mac · 生成邀请",()=>Safely(()=>{
            if(Program.Identity.Token!=null&&System.Windows.MessageBox.Show(this,"重新配对会断开当前 Mac。\n旧连接会失效，需要用新邀请重新连接。","重新连接设备",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)!=MessageBoxResult.Yes)return;
            Program.GenerateInvitation();inviteFeedback.Text="";Refresh();
        })));
        invitation.TextWrapping=TextWrapping.Wrap;invitation.Margin=new Thickness(0,2,0,12);invitation.Foreground=Muted;p.Children.Add(invitation);
        var actions=new C.WrapPanel();copy.Content="复制配对码";copy.Padding=new Thickness(16,8,16,8);copy.Margin=new Thickness(0,0,10,10);copy.Click+=(_,_)=>Safely(()=>{Program.CopyInvitation();inviteFeedback.Text="配对码已复制。请只粘贴到你自己的 Mac 版 CopyBridge。";});actions.Children.Add(copy);
        export.Content="保存配对文件…";export.Padding=new Thickness(16,8,16,8);export.Margin=new Thickness(0,0,10,10);export.Click+=(_,_)=>Safely(()=>{var dialog=new Microsoft.Win32.SaveFileDialog{Title="保存一次性配对文件",Filter="CopyBridge 配对文件|*.copybridge",FileName="连接这台Windows.copybridge",AddExtension=true,DefaultExt=".copybridge",OverwritePrompt=true};if(dialog.ShowDialog(this)==true){Program.ExportInvitation(dialog.FileName);inviteFeedback.Text="配对文件已保存。请把它交给你自己的 Mac。";}});actions.Children.Add(export);p.Children.Add(actions);inviteFeedback.TextWrapping=TextWrapping.Wrap;inviteFeedback.Foreground=Muted;inviteFeedback.Margin=new Thickness(0,0,0,10);p.Children.Add(inviteFeedback);
        p.Children.Add(Label("在 Mac 打开 CopyBridge → 连接设备，粘贴配对码或导入配对文件，再确认设备。\n邀请仅短期有效，使用一次即失效。CopyBridge 不会转发配对码。",13,null,Muted));
        p.Children.Add(Action("断开已配对的 Mac",()=>Safely(()=>{if(Program.Identity.Token==null)return;if(System.Windows.MessageBox.Show(this,"断开后，两台电脑都可以继续本地复制粘贴。\n以后可用新邀请重新连接。","断开设备",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)==MessageBoxResult.Yes)Program.DisconnectPeer();})));
        return Scroll(p);
    }
    C.ScrollViewer PreferencesPage() {
        var p=new C.StackPanel();p.Children.Add(Label("选择需要同步的内容",23,FontWeights.SemiBold));p.Children.Add(Label("两台电脑共享这份设置。在任意一端保存，另一端也会更新。",13,null,Muted));
        void Add(CheckBox box,string title,string help){box.Content=title;box.Padding=new Thickness(2,5,0,5);box.Margin=new Thickness(0,5,0,0);box.Checked+=Changed;box.Unchecked+=Changed;p.Children.Add(box);p.Children.Add(Label(help,12,null,Muted));}
        p.Children.Add(Label("同步方向",16,FontWeights.SemiBold));Add(toWindows,"Mac → Windows","在 Mac 复制后，可在 Windows 粘贴。");Add(toMac,"Windows → Mac","在 Windows 复制后，可在 Mac 粘贴。");
        p.Children.Add(Label("内容类型",16,FontWeights.SemiBold));Add(text,"文字","文字、链接和代码。");Add(image,"图片内容","截图或复制的图像像素。");Add(file,"文件","单个本地文件，最大 2 GiB；包含图片文件和视频文件。");Add(paused,"暂停全部同步","暂停后仍可修改设置。恢复时请重新复制内容。");
        var row=new C.WrapPanel{Margin=new Thickness(0,12,0,0)};row.Children.Add(Action("保存设置",Save));row.Children.Add(Action("重新载入",()=>{dirty=false;loadedRevision=-1;Refresh();feedback.Text="已载入两台电脑的最新设置。";}));p.Children.Add(row);
        feedback.TextWrapping=TextWrapping.Wrap;feedback.Foreground=Muted;p.Children.Add(feedback);return Scroll(p);
    }
    void Changed(object sender,RoutedEventArgs args){if(!loading){dirty=true;feedback.Text="修改尚未保存。";}}
    void Save() {try {var result=bridge.ApplySettings(new(loadedRevision,toWindows.IsChecked==true,toMac.IsChecked==true,text.IsChecked==true,image.IsChecked==true,file.IsChecked==true,paused.IsChecked==true));dirty=false;loadedRevision=-1;Refresh();feedback.Text=result.Paused?"已保存为暂停。另一台连接后会同步更新。":"已保存。另一台连接后会同步更新，请重新复制内容。";}catch(Exception e){feedback.Text=Explain(e);}}
    C.ScrollViewer ExplanationPage() {
        var p=new C.StackPanel();p.Children.Add(Label("复制之后，发生了什么？",23,FontWeights.SemiBold));
        foreach(var step in new[]{("1  复制","继续使用 Command+C 或 Ctrl+C，无需打开这个窗口。"),("2  加密直传","内容通过局域网直接传给已配对的电脑，不经过云账户或中转服务器。"),("3  核对完整性","文件完整收到并核对后，才放进另一台电脑的剪贴板。"),("4  可粘贴","在目标软件使用原来的粘贴快捷键。较大的文件需要等待就绪。")}){p.Children.Add(Label(step.Item1,17,FontWeights.SemiBold));p.Children.Add(Label(step.Item2,14,null,Muted));}
        p.Children.Add(Label("需要记住的三件事",16,FontWeights.SemiBold));p.Children.Add(Label("• 新复制优先，传输中的旧内容不会抢走本机新复制。\n• 连接、恢复或修改设置后，不补发旧剪贴板，请重新复制。\n• 软件是否接收视频或图片，仍取决于该软件的粘贴能力。",14,null,Muted));
        p.Children.Add(Action("打开已接收文件",()=>Program.OpenReceived()));p.Children.Add(Label("关闭设置窗口后，CopyBridge 仍在右下角托盘运行。",13,null,Muted));return Scroll(p);
    }
    static string FriendlyStatus(string status)=>status switch{"TYPE_DISABLED"=>"已跳过关闭的内容类型","DIRECTION_DISABLED"=>"这个同步方向已关闭","SENSITIVE_SOURCE"=>"已跳过私密内容","CLIPBOARD_BUSY"=>"剪贴板正忙，请稍后重新复制","SOURCE_UNAVAILABLE"=>"文件暂时无法读取，请检查后重新复制","SOURCE_CHANGED"=>"文件发生变化，请完成编辑后重新复制","SIZE_LIMIT"=>"内容超出当前大小限制","SESSION_REVOKED"=>"正在重新连接，请重新复制",_=>status};
    void Refresh() {
        connection.Text=bridge.Paused?"● 已暂停同步":Program.Identity.Token==null?"● 尚未连接设备":!Program.PeerRecentlySeen?"● 已配对，等待 Mac 上线":"● "+FriendlyStatus(bridge.Status);
        peer.Text=Program.Identity.Peer is string id?"对方  ·  已配对的 Mac（"+id[^8..]+"）":"对方  ·  等待连接";
        bool available=Program.InvitationAvailable;copy.IsEnabled=available;export.IsEnabled=available;
        invitation.Text=available?"一次性邀请已准备，还可使用约 "+Math.Max(1,(int)Math.Ceiling((Program.Identity.Expires-DateTimeOffset.UtcNow).TotalMinutes))+" 分钟。":Program.Identity.Token!=null?"设备已配对，邀请已失效。":"生成邀请后，可以复制配对码或保存配对文件。";
        var settings=bridge.Settings.Current;
        if(!dirty&&loadedRevision!=settings.Revision){loading=true;toWindows.IsChecked=settings.MacToWindows;toMac.IsChecked=settings.WindowsToMac;text.IsChecked=settings.Text;image.IsChecked=settings.Image;file.IsChecked=settings.File;paused.IsChecked=settings.Paused;loadedRevision=settings.Revision;loading=false;}
        else if(dirty&&loadedRevision!=settings.Revision)feedback.Text="另一台电脑更新了设置。请先重新载入，再保存你的修改。";
    }
}
