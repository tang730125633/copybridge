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
    readonly C.ContentControl host=new();
    readonly List<C.RadioButton> navigation=new();
    readonly List<C.ScrollViewer> pages=new();
    readonly TextBlock homeTitle=new(),homeSubtitle=new(),homeState=new(),homeHint=new(),railState=new(),peer=new(),invitation=new(),inviteFeedback=new(),feedback=new(),shortcutFeedback=new();
    readonly Button homeConnect=new(),homePause=new(),copy=new(),export=new();
    readonly C.TextBox quickAddress=new(),quickCode=new();
    readonly C.StackPanel pairingSteps=new(),pairedInfo=new();
    C.Border pairedCard=null!;
    readonly System.Windows.Shapes.Ellipse stateDot=new(){Width=8,Height=8,Margin=new Thickness(0,0,9,0)};
    readonly CheckBox toWindows=new(),toMac=new(),text=new(),image=new(),file=new(),paused=new();
    readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromSeconds(1)};
    long loadedRevision=-1;bool dirty,loading;
    static Brush Hex(string value)=>(Brush)new BrushConverter().ConvertFromString(value)!;
    static readonly Brush Ink=Hex("#1A2B4A"),Muted=Hex("#5F6E87"),Blue=Hex("#3563E9"),Line=Hex("#E4EAF3");
    internal SettingsWindow(Bridge value) {
        bridge=value;Title="CopyBridge";Width=1040;Height=800;MinWidth=860;MinHeight=660;WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Icon=new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/AppIcon.ico"));
        Background=System.Windows.Media.Brushes.White;Foreground=Ink;FontFamily=new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI");FontSize=14;UseLayoutRounding=true;
        Resources.MergedDictionaries.Add((ResourceDictionary)System.Windows.Application.LoadComponent(new Uri("/CopyBridge;component/WindowTheme.xaml",UriKind.Relative)));
        var root=new C.Grid();root.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new GridLength(190)});root.ColumnDefinitions.Add(new C.ColumnDefinition());
        var rail=new C.DockPanel{Margin=new Thickness(18,28,18,22)};
        var brand=new C.StackPanel{Margin=new Thickness(12,0,0,32)};
        var brandIcon=new C.Image{Source=new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/AppIcon.png")),Width=52,Height=52,HorizontalAlignment=System.Windows.HorizontalAlignment.Left,Margin=new Thickness(0,0,0,12)};
        AutomationProperties.SetName(brandIcon,"CopyBridge 图标");brand.Children.Add(brandIcon);brand.Children.Add(Label("CopyBridge",21,FontWeights.SemiBold));brand.Children.Add(Label("让复制接着走",12,null,Muted));C.DockPanel.SetDock(brand,C.Dock.Top);rail.Children.Add(brand);
        var footer=new C.StackPanel{Margin=new Thickness(12,16,0,0)};railState.FontSize=12;railState.Foreground=Muted;railState.TextWrapping=TextWrapping.Wrap;footer.Children.Add(railState);footer.Children.Add(Label("Windows 试用版 0.4",11,null,Muted));C.DockPanel.SetDock(footer,C.Dock.Bottom);rail.Children.Add(footer);
        var nav=new C.StackPanel();string[] titles=["我的设备","连接 Mac","同步偏好","使用指南"];
        for(int i=0;i<titles.Length;i++){int index=i;var item=new C.RadioButton{Content=titles[i],GroupName="Navigation",Style=(Style)FindResource("Nav")};AutomationProperties.SetName(item,titles[i]);item.Checked+=(_,_)=>ShowPage(index);navigation.Add(item);nav.Children.Add(item);}rail.Children.Add(nav);
        var sidebar=new C.Border{Background=Hex("#F4F7FC"),BorderBrush=Line,BorderThickness=new Thickness(0,0,1,0),Child=rail};root.Children.Add(sidebar);
        host.Margin=new Thickness(36,30,30,20);C.Grid.SetColumn(host,1);root.Children.Add(host);Content=root;
        pages.Add(HomePage());pages.Add(ConnectionPage());pages.Add(PreferencesPage());pages.Add(GuidePage());navigation[0].IsChecked=true;
        bridge.Changed+=Refresh;timer.Tick+=(_,_)=>Refresh();timer.Start();Closed+=(_,_)=>{timer.Stop();bridge.Changed-=Refresh;};Refresh();
    }
    void ShowPage(int index){if(index>=pages.Count)return;host.Content=pages[index];navigation[index].IsChecked=true;Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle,new System.Action(()=>pages[index].ScrollToTop()));}
    static TextBlock Label(string value,double size=14,FontWeight? weight=null,Brush? color=null)=>new(){Text=value,FontSize=size,FontWeight=weight??FontWeights.Normal,Foreground=color??Ink,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,8)};
    static C.StackPanel Stack(params UIElement[] children){var panel=new C.StackPanel();foreach(var child in children)panel.Children.Add(child);return panel;}
    static C.WrapPanel Row(params UIElement[] children){var panel=new C.WrapPanel{Margin=new Thickness(0,8,0,0)};foreach(var child in children){if(child is FrameworkElement element)element.Margin=new Thickness(0,0,10,8);panel.Children.Add(child);}return panel;}
    static C.Border Box(UIElement child,Brush? fill=null)=>new(){Child=child,Background=fill??Hex("#F7F9FD"),CornerRadius=new CornerRadius(14),Padding=new Thickness(22),Margin=new Thickness(0,10,0,18)};
    static C.ScrollViewer Scroll(C.StackPanel content)=>new(){Content=content,VerticalScrollBarVisibility=C.ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=C.ScrollBarVisibility.Disabled,Padding=new Thickness(0,0,10,6),Focusable=false};
    Button Action(string title,System.Action action,bool primary=false){var b=new Button{Content=title};if(primary)b.Style=(Style)FindResource("Primary");b.Click+=(_,_)=>action();return b;}
    static void TextStyle(TextBlock target,double size,Brush? color=null){target.FontSize=size;target.Foreground=color??Ink;target.TextWrapping=TextWrapping.Wrap;target.Margin=new Thickness(0,0,0,10);}
    static C.StackPanel Step(string number,string title,string body){var row=new C.Grid{Margin=new Thickness(0,8,0,8)};row.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new GridLength(40)});row.ColumnDefinitions.Add(new C.ColumnDefinition());row.Children.Add(new C.Border{Width=28,Height=28,VerticalAlignment=System.Windows.VerticalAlignment.Top,HorizontalAlignment=System.Windows.HorizontalAlignment.Left,CornerRadius=new CornerRadius(14),Background=Hex("#E5EDFF"),Child=new TextBlock{Text=number,Foreground=Blue,HorizontalAlignment=System.Windows.HorizontalAlignment.Center,VerticalAlignment=System.Windows.VerticalAlignment.Center,FontWeight=FontWeights.SemiBold}});var words=Stack(Label(title,15,FontWeights.SemiBold),Label(body,13,null,Muted));C.Grid.SetColumn(words,1);row.Children.Add(words);return Stack(row);}
    static C.StackPanel Device(string name,string type,string symbol){var screen=new C.Border{Width=112,Height=68,CornerRadius=new CornerRadius(8),BorderBrush=Hex("#A8BADE"),BorderThickness=new Thickness(2),Background=System.Windows.Media.Brushes.White,Child=new TextBlock{Text=symbol,FontSize=28,Foreground=Blue,VerticalAlignment=System.Windows.VerticalAlignment.Center,HorizontalAlignment=System.Windows.HorizontalAlignment.Center}};var stand=new C.Border{Width=38,Height=4,Background=Hex("#A8BADE"),CornerRadius=new CornerRadius(2),Margin=new Thickness(0,6,0,12)};var a=Label(name,14,FontWeights.SemiBold);a.TextAlignment=TextAlignment.Center;var b=Label(type,12,null,Muted);b.TextAlignment=TextAlignment.Center;return Stack(screen,stand,a,b);}
    C.ScrollViewer HomePage(){
        TextStyle(homeTitle,28);homeTitle.FontWeight=FontWeights.SemiBold;TextStyle(homeSubtitle,14,Muted);
        var devices=new C.Grid{Margin=new Thickness(0,10,0,14)};devices.ColumnDefinitions.Add(new C.ColumnDefinition());devices.ColumnDefinitions.Add(new C.ColumnDefinition{Width=new GridLength(70)});devices.ColumnDefinitions.Add(new C.ColumnDefinition());
        devices.Children.Add(Device("这台 Windows",Environment.MachineName,"⊞"));var arrow=Label("⇄",30,null,Blue);arrow.HorizontalAlignment=System.Windows.HorizontalAlignment.Center;arrow.VerticalAlignment=System.Windows.VerticalAlignment.Center;arrow.Margin=new Thickness(0,0,0,35);C.Grid.SetColumn(arrow,1);devices.Children.Add(arrow);var mac=Device("你的 Mac","打开 Mac 版 CopyBridge","⌘");C.Grid.SetColumn(mac,2);devices.Children.Add(mac);
        TextStyle(homeState,15);homeState.FontWeight=FontWeights.SemiBold;homeState.Margin=new Thickness(0);var status=new C.StackPanel{Orientation=C.Orientation.Horizontal,Margin=new Thickness(0,0,0,10)};status.Children.Add(stateDot);status.Children.Add(homeState);TextStyle(homeHint,13,Muted);
        homeConnect.Style=(Style)FindResource("Primary");homeConnect.Click+=(_,_)=>ShowPage(1);homePause.Content="暂停同步";homePause.Click+=(_,_)=>Safely(()=>bridge.Pause(!bridge.Paused));
        var panel=Stack(homeTitle,homeSubtitle,Box(Stack(devices,status,homeHint,Row(homeConnect,homePause))),Label("第一次，用一小段文字试试",18,FontWeights.SemiBold),Step("1","在 Windows 复制","选中一段文字，按 Ctrl + C"),Step("2","到 Mac 粘贴","Mac 显示「Mac 可粘贴」后，按 ⌘ V"),Label("反过来也一样：Mac 按 ⌘ C，Windows 按 Ctrl + V",13,null,Muted),Row(Action("打开收到的文件",()=>Safely(Program.OpenReceived)),Action("查看完整指南",()=>ShowPage(3))),Label("关闭窗口后仍在后台同步，下次双击 CopyBridge 即可回来",12,null,Muted));return Scroll(panel);
    }
    C.ScrollViewer ConnectionPage(){
        var panel=Stack(Label("把两台电脑连起来",28,FontWeights.SemiBold),Label("只在第一次连接时操作，以后打开就能继续用",14,null,Muted));
        pairedInfo.Children.Add(Label("你的 Mac 已经配对",19,FontWeights.SemiBold));TextStyle(peer,14,Muted);pairedInfo.Children.Add(peer);pairedInfo.Children.Add(Row(Action("回到我的设备",()=>ShowPage(0),true)));
        var replace=Stack(Label("重新配对会让旧连接失效，需要在 Mac 再确认一次",13,null,Muted),Row(Action("准备连接新设备",GenerateInvitation),Action("断开当前 Mac",Disconnect)));
        pairedInfo.Children.Add(new C.Expander{Header="更换或断开设备",Content=replace,Margin=new Thickness(0,12,0,0)});pairedCard=Box(pairedInfo);panel.Children.Add(pairedCard);
        pairingSteps.Children.Add(Label("只需要地址和短口令",20,FontWeights.SemiBold));
        pairingSteps.Children.Add(Label("在 Mac 的「连接设备」填写下面两项，或直接粘贴整行连接信息",14,null,Muted));
        foreach(var input in new[]{quickAddress,quickCode}){input.IsReadOnly=true;input.FontSize=18;input.Padding=new Thickness(12);input.Margin=new Thickness(0,0,0,14);input.BorderBrush=Line;input.BorderThickness=new Thickness(1);}
        quickAddress.Text=Program.QuickAddress;AutomationProperties.SetName(quickAddress,"Windows 地址");AutomationProperties.SetName(quickCode,"短连接口令");
        pairingSteps.Children.Add(Label("Windows 地址",14,FontWeights.SemiBold));pairingSteps.Children.Add(quickAddress);pairingSteps.Children.Add(Label("连接口令",14,FontWeights.SemiBold));pairingSteps.Children.Add(quickCode);
        copy.Content="复制连接信息";copy.Style=(Style)FindResource("Primary");copy.Click+=(_,_)=>Safely(()=>{Program.CopyQuickConnection();Refresh();inviteFeedback.Text="已复制一行连接信息。到 Mac 点击「粘贴连接信息」，再点「连接」。";});
        pairingSteps.Children.Add(Row(copy));TextStyle(invitation,13,Muted);pairingSteps.Children.Add(invitation);TextStyle(inviteFeedback,13,Blue);pairingSteps.Children.Add(inviteFeedback);
        export.Content="保存旧版配对文件";export.Click+=(_,_)=>SaveInvite();var oldCode=Action("复制旧版长码",()=>Safely(Program.CopyInvitation));pairingSteps.Children.Add(new C.Expander{Header="兼容旧版客户端",Content=Row(export,oldCode,Action("刷新连接信息",GenerateInvitation)),Margin=new Thickness(0,20,0,0)});panel.Children.Add(pairingSteps);
        var detail=Stack(Label("Windows 连接地址",13,FontWeights.SemiBold),new C.TextBox{Text=Program.Origin,IsReadOnly=true,Padding=new Thickness(12),BorderBrush=Line,BorderThickness=new Thickness(1)},Label("地址由程序自动选择，不需要手动填写",12,null,Muted));panel.Children.Add(new C.Expander{Header="连接不上？查看网络检查",Margin=new Thickness(0,24,0,0),Content=Stack(Step("1","先检查网络","避免使用访客 Wi-Fi；确认两台电脑都已打开 CopyBridge"),Step("2","检查 Windows 的网络提示","仅在你信任的专用网络允许 CopyBridge 通信，不要关闭整机防火墙"),detail)});
        if(Program.Origin.Contains("127.0.0.1"))panel.Children.Add(Label("当前没有可用的局域网地址，请连接网络后退出并重新打开",13,null,Hex("#AD6516")));return Scroll(panel);
    }
    void GenerateInvitation()=>Safely(()=>{if(Program.Identity.Token!=null&&System.Windows.MessageBox.Show(this,"重新配对会断开当前 Mac，需要在 Mac 导入新文件。继续吗？","更换设备",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)!=MessageBoxResult.Yes)return;Program.GenerateInvitation();inviteFeedback.Text="新的连接信息已准备";Refresh();});
    void Disconnect()=>Safely(()=>{if(Program.Identity.Token!=null&&System.Windows.MessageBox.Show(this,"断开后不会影响本机复制粘贴，以后可以重新连接。","断开设备",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)==MessageBoxResult.Yes)Program.DisconnectPeer();});
    void SaveInvite()=>Safely(()=>{var dialog=new Microsoft.Win32.SaveFileDialog{Title="保存一次性配对文件",Filter="CopyBridge 配对文件|*.copybridge",FileName="连接这台Windows.copybridge",AddExtension=true,DefaultExt=".copybridge",OverwritePrompt=true};if(dialog.ShowDialog(this)==true){Program.ExportInvitation(dialog.FileName);inviteFeedback.Text="已保存，现在把文件交给你的 Mac，再按第 3 步操作";}});
    C.ScrollViewer PreferencesPage(){
        var panel=Stack(Label("按照你的习惯同步",28,FontWeights.SemiBold),Label("在任意一台保存，另一台也会更新",14,null,Muted));
        void Add(C.StackPanel group,CheckBox box,string title,string hint){box.Content=title;box.Checked+=Changed;box.Unchecked+=Changed;group.Children.Add(box);var help=Label(hint,12,null,Muted);help.Margin=new Thickness(28,0,0,14);group.Children.Add(help);}
        var directions=Stack(Label("同步方向",17,FontWeights.SemiBold));Add(directions,toWindows,"Mac → Windows","在 Mac 复制，到 Windows 粘贴");Add(directions,toMac,"Windows → Mac","在 Windows 复制，到 Mac 粘贴");panel.Children.Add(Box(directions));
        var types=Stack(Label("同步内容",17,FontWeights.SemiBold));Add(types,text,"文字与链接","文字、网址、代码");Add(types,image,"截图与图片内容","直接复制的图片或截图");Add(types,file,"单个文件","图片文件、文档和视频等，最大 2 GiB");panel.Children.Add(Box(types));Add(panel,paused,"暂停全部同步","恢复后，请重新复制需要的内容");
        panel.Children.Add(Row(Action("保存到两台设备",Save,true),Action("重新载入",()=>{dirty=false;loadedRevision=-1;Refresh();feedback.Text="已载入最新设置";})));TextStyle(feedback,13,Muted);panel.Children.Add(feedback);return Scroll(panel);
    }
    void Changed(object sender,RoutedEventArgs args){if(!loading){dirty=true;feedback.Text="有尚未保存的修改";}}
    void Save(){try{var result=bridge.ApplySettings(new(loadedRevision,toWindows.IsChecked==true,toMac.IsChecked==true,text.IsChecked==true,image.IsChecked==true,file.IsChecked==true,paused.IsChecked==true));dirty=false;loadedRevision=-1;Refresh();feedback.Text=result.Paused?"已保存，同步暂停中":"已保存，请重新复制需要同步的内容";}catch(Exception e){feedback.Text=Explain(e);}}
    C.ScrollViewer GuidePage(){
        var panel=Stack(Label("拿到 CopyBridge 之后",28,FontWeights.SemiBold),Label("不用注册账号，先让两台电脑认识彼此",14,null,Muted),Step("1","各自打开对应版本","Windows 解压整个文件夹，双击 CopyBridge.exe；Mac 将 CopyBridge.app 放入「应用程序」后打开"),Step("2","完成一次配对","让两台电脑处于同一网络，按「连接 Mac」页面的步骤操作"),Step("3","先用一句话试试","Windows 复制一段新文字，看到 Mac 就绪后再粘贴；然后交换方向试一次"),Row(Action("去连接 Mac",()=>ShowPage(1),true),Action("添加桌面快捷方式",()=>Safely(()=>{Program.CreateDesktopShortcut();shortcutFeedback.Text="桌面入口已添加，以后双击 CopyBridge 就能打开";}))));
        TextStyle(shortcutFeedback,13,Blue);panel.Children.Add(shortcutFeedback);
        panel.Children.Add(Box(Stack(Label("重启电脑后怎么开始",18,FontWeights.SemiBold),Label("在 Windows 和 Mac 各双击桌面的 CopyBridge",14),Label("程序会沿用原配对尝试连接；看到已连接后，重新复制一次",14),Label("不用重新导入配对文件。若连不上，先检查另一台是否已打开，并确认网络可以互通",13,null,Muted))));
        panel.Children.Add(Box(Stack(Label("用的时候，记住这几件事",18,FontWeights.SemiBold),Label("两台电脑都要开着 CopyBridge；关闭窗口不会退出程序",14),Label("每次连接或恢复后，重新复制一次，旧内容不会自动补发",14),Label("文件要等传完再粘贴；暂不支持文件夹和一次复制多个文件",14),Label("发送截图和复制图片文件是两种方式，可分别控制",14))));
        panel.Children.Add(Label("给朋友分享时",18,FontWeights.SemiBold));panel.Children.Add(Label("分享原始试用包，让对方在自己的两台电脑上配对。不要把你生成的连接文件当作安装包发送。",14,null,Muted));panel.Children.Add(Label("这是本地试用版，尚未完成正式签名。遇到系统拦截先核对来源，不要关闭系统保护。",12,null,Muted));return Scroll(panel);
    }
    void Safely(System.Action action){try{action();}catch(Exception e){System.Windows.MessageBox.Show(this,Explain(e),"CopyBridge",MessageBoxButton.OK,MessageBoxImage.Information);}}
    static string Explain(Exception e)=>e is Fault f?f.Message switch{"SETTINGS_CONFLICT"=>"另一台电脑更新了设置，请重新载入后再保存","CLIPBOARD_BUSY"=>"剪贴板正忙，请稍后重试","SESSION_LOCKED"=>"请先解锁 Windows","INVITATION_UNAVAILABLE"=>"连接文件已过期或已被使用，请刷新有效期","ADDRESS_CERTIFICATE_MISMATCH"=>"网络地址发生变化，请恢复配对时的网络后重试",_=>"操作未完成，请检查两台电脑的连接后重试"}:"无法完成操作，请检查可用空间和文件权限";
    static string FriendlyStatus(string status)=>status switch{"TYPE_DISABLED"=>"本次内容类型未开启同步","DIRECTION_DISABLED"=>"这个方向已关闭同步","SENSITIVE_SOURCE"=>"已跳过私密内容","CLIPBOARD_BUSY"=>"剪贴板正忙，请稍后重新复制","SOURCE_UNAVAILABLE"=>"文件暂时无法读取，请重新复制","SOURCE_CHANGED"=>"文件有变化，请完成编辑后重新复制","SIZE_LIMIT"=>"内容超过大小限制","SESSION_REVOKED"=>"正在重新连接，请重新复制","SUPERSEDED"=>"已保留最新复制的内容",_=>status};
    void Refresh(){
        bool paired=Program.Identity.Token!=null,online=Program.PeerRecentlySeen;
        homeTitle.Text=paired?"这边复制，那边继续":"让两台电脑，共用复制粘贴";
        homeSubtitle.Text=paired?"文字、截图和文件，沿用你熟悉的快捷键":"先连接你的 Mac，之后就像在同一台电脑上操作";
        string state=!paired?"等待连接 Mac":bridge.Paused?"同步已暂停":!online?"已配对，等待 Mac 上线":"两台电脑已连接";
        railState.Text=state;homeState.Text=state;stateDot.Fill=paired&&online&&!bridge.Paused?Hex("#127C5D"):Hex("#8090A8");
        homeHint.Text=!paired?"第一次只需完成一次配对，点击下方开始":bridge.Paused?"点击恢复后，请重新复制需要的内容":!online?"请在 Mac 打开 CopyBridge，并确认两台电脑在同一网络":FriendlyStatus(bridge.Status);
        homeConnect.Content=paired?"查看连接":"连接我的 Mac";homePause.Content=bridge.Paused?"恢复同步":"暂停同步";homePause.Visibility=paired?Visibility.Visible:Visibility.Collapsed;
        pairedCard.Visibility=paired?Visibility.Visible:Visibility.Collapsed;pairingSteps.Visibility=paired?Visibility.Collapsed:Visibility.Visible;
        peer.Text=online?"两台设备保持连接，今后不用重复配对":"配对关系已保存，请在 Mac 打开 CopyBridge";
        bool available=Program.InvitationAvailable;copy.IsEnabled=!paired;export.IsEnabled=available;
        quickCode.Text=Program.QuickCode;
        invitation.Text=available?"10 分钟内有效；连接成功后自动保存，以后不用再填":"点击「复制连接信息」即可准备新的短口令";
        var settings=bridge.Settings.Current;
        if(!dirty&&loadedRevision!=settings.Revision){loading=true;toWindows.IsChecked=settings.MacToWindows;toMac.IsChecked=settings.WindowsToMac;text.IsChecked=settings.Text;image.IsChecked=settings.Image;file.IsChecked=settings.File;paused.IsChecked=settings.Paused;loadedRevision=settings.Revision;loading=false;}
        else if(dirty&&loadedRevision!=settings.Revision)feedback.Text="另一台更新了设置，请重新载入后再保存";
    }
}
