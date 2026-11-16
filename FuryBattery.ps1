# FuryBattery — заряд мышки FuryCube G3 в трее и оверлее.
# Запускайте через FuryBattery.vbs (так не будет чёрного окна консоли).

$code = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace FuryBattery
{
    // ---------- Низкоуровневая работа с USB HID (встроено в Windows) ----------
    public static class FuryHid
    {
        [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
        [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr pd);
        [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pd);
        [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr pd, out HIDP_CAPS caps);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, int flags);
        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, int index, ref SP_DEVICE_INTERFACE_DATA data);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int detailSize, out int required, IntPtr devInfo);
        [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle h, byte[] buf, int len, out int read, IntPtr ovl);

        [StructLayout(LayoutKind.Sequential)]
        public struct SP_DEVICE_INTERFACE_DATA
        {
            public int cbSize;
            public Guid InterfaceClassGuid;
            public int Flags;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct HIDP_CAPS
        {
            public ushort Usage;
            public ushort UsagePage;
            public ushort InputReportByteLength;
            public ushort OutputReportByteLength;
            public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps;
            public ushort NumberInputValueCaps;
            public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps;
            public ushort NumberOutputValueCaps;
            public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps;
            public ushort NumberFeatureValueCaps;
            public ushort NumberFeatureDataIndices;
        }

        // Список путей ко всем HID-устройствам, в имени которых есть vidTag
        public static List<string> FindPaths(string vidTag)
        {
            List<string> result = new List<string>();
            Guid g;
            HidD_GetHidGuid(out g);
            IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // PRESENT | DEVICEINTERFACE
            if (set == IntPtr.Zero || set == new IntPtr(-1)) return result;
            try
            {
                for (int i = 0; ; i++)
                {
                    SP_DEVICE_INTERFACE_DATA d = new SP_DEVICE_INTERFACE_DATA();
                    d.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                    int req;
                    SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                    if (req <= 0) continue;
                    IntPtr buf = Marshal.AllocHGlobal(req);
                    try
                    {
                        Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                        if (SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero))
                        {
                            string p = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                            if (p != null && p.ToLowerInvariant().Contains(vidTag)) result.Add(p);
                        }
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
            return result;
        }
    }

    // ---------- Чтение заряда из донгла ----------
    // Донгл (USB 1d57:fa60) раз в ~2 секунды сам присылает пакет: 03 66 41 <состояние> <заряд %>
    public class BatteryReader
    {
        public readonly object Lock = new object();
        public int Battery = -1;
        public int State = -1;
        public DateTime LastSeen = DateTime.MinValue;
        public string LastRaw = "";
        public string LastAnyRaw = "";
        public List<string> Log = new List<string>();

        Dictionary<string, Thread> active = new Dictionary<string, Thread>();
        Dictionary<string, bool> failed = new Dictionary<string, bool>();
        int lastFoundCount = -1;

        void AddLog(string s)
        {
            lock (Lock)
            {
                Log.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + s);
                if (Log.Count > 40) Log.RemoveAt(0);
            }
        }

        static string ShortPath(string p)
        {
            string low = p.ToLowerInvariant();
            int i = low.IndexOf("vid_");
            if (i < 0) return p;
            string s = p.Substring(i);
            int j = s.IndexOf('#');
            return j > 0 ? s.Substring(0, j) : s;
        }

        static string Hex(byte[] b, int n)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < n && i < 16; i++) sb.Append(b[i].ToString("X2")).Append(' ');
            return sb.ToString().Trim();
        }

        public void Scan()
        {
            List<string> paths;
            try { paths = FuryHid.FindPaths("vid_1d57"); }
            catch (Exception ex) { AddLog("Ошибка поиска устройств: " + ex.Message); return; }

            if (paths.Count != lastFoundCount)
            {
                lastFoundCount = paths.Count;
                if (paths.Count == 0) AddLog("Донгл FuryCube (1d57) не найден");
                else AddLog("Найдено интерфейсов донгла: " + paths.Count);
            }

            foreach (string p in paths)
            {
                lock (Lock) { if (active.ContainsKey(p)) continue; }

                SafeFileHandle h = FuryHid.CreateFile(p, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (h.IsInvalid)
                {
                    // Клавиатурные/мышиные интерфейсы Windows не даёт открыть — это нормально
                    if (!failed.ContainsKey(p)) { failed[p] = true; AddLog("Пропущен (занят Windows): " + ShortPath(p)); }
                    continue;
                }

                int len = 0;
                int usagePage = 0;
                IntPtr pd;
                if (FuryHid.HidD_GetPreparsedData(h, out pd))
                {
                    FuryHid.HIDP_CAPS caps;
                    FuryHid.HidP_GetCaps(pd, out caps);
                    FuryHid.HidD_FreePreparsedData(pd);
                    len = caps.InputReportByteLength;
                    usagePage = caps.UsagePage;
                }
                if (len <= 0) { h.Close(); continue; }

                AddLog("Слушаю: " + ShortPath(p) + " (usage page 0x" + usagePage.ToString("X4") + ", пакет " + len + " байт)");

                string path = p;
                SafeFileHandle handle = h;
                int length = len;
                Thread t = new Thread(delegate () { ReadLoop(path, handle, length); });
                t.IsBackground = true;
                lock (Lock) { active[p] = t; }
                t.Start();
            }
        }

        void ReadLoop(string path, SafeFileHandle h, int len)
        {
            byte[] buf = new byte[Math.Max(len, 8)];
            try
            {
                while (true)
                {
                    int n;
                    if (!FuryHid.ReadFile(h, buf, len, out n, IntPtr.Zero) || n <= 0) break;
                    Parse(buf, n);
                }
            }
            catch (Exception) { }
            finally
            {
                try { h.Close(); } catch (Exception) { }
                lock (Lock) { active.Remove(path); }
                AddLog("Отключено: " + ShortPath(path));
            }
        }

        void Parse(byte[] b, int n)
        {
            string raw = Hex(b, n);
            lock (Lock) { LastAnyRaw = raw; }
            if (n >= 5 && b[0] == 0x03 && b[1] == 0x66 && b[2] == 0x41)
            {
                int bat = b[4];
                lock (Lock)
                {
                    if (bat <= 100) Battery = bat;
                    State = b[3];
                    LastSeen = DateTime.Now;
                    LastRaw = raw;
                }
            }
        }
    }

    public static class Ui
    {
        public static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    // ---------- Оверлей: маленькая плашка поверх всех окон, клики проходят сквозь неё ----------
    public class OverlayForm : Form
    {
        string text = "";
        Color color = Color.White;
        float scale;

        public OverlayForm(float scale)
        {
            this.scale = scale;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(24, 24, 24);
            Opacity = 0.85;
            Size = new Size((int)(124 * scale), (int)(34 * scale));
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            using (GraphicsPath p = Ui.RoundRect(new RectangleF(0, 0, Width, Height), 8 * scale))
            {
                Region = new Region(p);
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                // TRANSPARENT (клики насквозь) | TOOLWINDOW (нет в Alt+Tab) | LAYERED | TOPMOST | NOACTIVATE
                cp.ExStyle |= 0x20 | 0x80 | 0x80000 | 0x8 | 0x08000000;
                return cp;
            }
        }

        public void SetValue(string t, Color c)
        {
            if (t != text || c != color)
            {
                text = t;
                color = c;
                Invalidate();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            e.Graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using (Font f = new Font("Segoe UI", 16f * scale, FontStyle.Bold, GraphicsUnit.Pixel))
            using (SolidBrush b = new SolidBrush(color))
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                e.Graphics.DrawString(text, f, b, new RectangleF(0, 0, Width, Height), sf);
            }
        }
    }

    // ---------- Значок в трее, меню, настройки ----------
    public class TrayApp : ApplicationContext
    {
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "FuryBattery";

        static readonly Color Green = Color.FromArgb(76, 175, 80);
        static readonly Color Yellow = Color.FromArgb(255, 193, 7);
        static readonly Color Red = Color.FromArgb(244, 67, 54);
        static readonly Color Gray = Color.FromArgb(140, 140, 140);

        BatteryReader reader = new BatteryReader();
        NotifyIcon tray;
        OverlayForm overlay;
        ContextMenuStrip menu;
        System.Windows.Forms.Timer uiTimer;
        System.Windows.Forms.Timer scanTimer;

        string dir;
        string settingsPath;
        string overlayMode = "low"; // always | low | off
        string corner = "TL";       // TL | TR | BL | BR
        int threshold = 20;

        int notifiedLevel = 101;
        IntPtr lastHicon = IntPtr.Zero;
        int shownBat = -2;
        bool shownStale = false;
        float scale = 1f;

        ToolStripMenuItem headerItem, autoItem, ovAlways, ovLow, ovOff;
        Dictionary<string, ToolStripMenuItem> cornerItems = new Dictionary<string, ToolStripMenuItem>();

        public TrayApp(string dir)
        {
            this.dir = dir;
            string appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FuryBattery");
            Directory.CreateDirectory(appData);
            settingsPath = Path.Combine(appData, "settings.txt");
            LoadSettings();

            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { scale = g.DpiX / 96f; }

            overlay = new OverlayForm(scale);
            BuildMenu();

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.Visible = true;

            UpdateUi(true);
            reader.Scan();

            scanTimer = new System.Windows.Forms.Timer();
            scanTimer.Interval = 5000;
            scanTimer.Tick += (s, e) => reader.Scan();
            scanTimer.Start();

            uiTimer = new System.Windows.Forms.Timer();
            uiTimer.Interval = 1000;
            uiTimer.Tick += (s, e) => UpdateUi(false);
            uiTimer.Start();
        }

        Color ColorFor(int bat, bool stale)
        {
            if (stale || bat < 0) return Gray;
            if (bat <= threshold) return Red;
            if (bat <= 50) return Yellow;
            return Green;
        }

        void UpdateUi(bool force)
        {
            int bat;
            DateTime seen;
            lock (reader.Lock) { bat = reader.Battery; seen = reader.LastSeen; }
            bool stale = bat < 0 || (DateTime.Now - seen).TotalSeconds > 15;
            Color c = ColorFor(bat, stale);

            if (force || bat != shownBat || stale != shownStale)
            {
                shownBat = bat;
                shownStale = stale;
                SetTrayIcon(bat, c, stale);
                string tip;
                if (bat < 0) tip = "FuryCube G3: нет данных";
                else if (stale) tip = "FuryCube G3: нет связи (было " + bat + "%)";
                else tip = "FuryCube G3: заряд " + bat + "%";
                tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
                headerItem.Text = tip;
            }

            // Уведомления
            if (!stale && bat >= 0)
            {
                if (bat <= 10 && notifiedLevel > 10)
                {
                    tray.ShowBalloonTip(6000, "FuryCube G3", "Мышка почти разряжена: " + bat + "%. Поставьте на зарядку.", ToolTipIcon.Warning);
                    notifiedLevel = 10;
                }
                else if (bat <= threshold && notifiedLevel > threshold)
                {
                    tray.ShowBalloonTip(6000, "FuryCube G3", "Низкий заряд мышки: " + bat + "%", ToolTipIcon.Info);
                    notifiedLevel = threshold;
                }
                else if (bat >= threshold + 5)
                {
                    notifiedLevel = 101;
                }
            }

            // Оверлей
            bool show = bat >= 0 && (overlayMode == "always" || (overlayMode == "low" && bat <= threshold));
            if (show)
            {
                overlay.SetValue("Мышь " + bat + "%", c);
                PlaceOverlay();
                if (!overlay.Visible) overlay.Show();
                // Держим поверх окон (игры иногда перекрывают)
                SetWindowPos(overlay.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
            }
            else if (overlay.Visible)
            {
                overlay.Hide();
            }
        }

        void PlaceOverlay()
        {
            Rectangle b = Screen.PrimaryScreen.Bounds;
            int m = (int)(12 * scale);
            int x = corner.EndsWith("R") ? b.Right - overlay.Width - m : b.Left + m;
            int y = corner.StartsWith("B") ? b.Bottom - overlay.Height - m - (int)(40 * scale) : b.Top + m;
            if (overlay.Left != x || overlay.Top != y) overlay.Location = new Point(x, y);
        }

        void SetTrayIcon(int bat, Color c, bool stale)
        {
            int size = SystemInformation.SmallIconSize.Width;
            if (size < 16) size = 16;
            using (Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (GraphicsPath p = Ui.RoundRect(new RectangleF(0, 0, size - 1, size - 1), size / 5f))
                    using (SolidBrush br = new SolidBrush(c))
                    {
                        g.FillPath(br, p);
                    }
                    string txt = bat < 0 ? "?" : bat.ToString();
                    float fs = size * (txt.Length >= 3 ? 0.50f : 0.72f);
                    Color tc = (c == Red || c == Gray) ? Color.White : Color.Black;
                    using (Font f = new Font("Segoe UI", fs, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (SolidBrush tb = new SolidBrush(tc))
                    using (StringFormat sf = new StringFormat())
                    {
                        sf.Alignment = StringAlignment.Center;
                        sf.LineAlignment = StringAlignment.Center;
                        g.DrawString(txt, f, tb, new RectangleF(-1, 0, size + 2, size), sf);
                    }
                }
                IntPtr h = bmp.GetHicon();
                tray.Icon = Icon.FromHandle(h);
                if (lastHicon != IntPtr.Zero) DestroyIcon(lastHicon);
                lastHicon = h;
            }
        }

        void BuildMenu()
        {
            menu = new ContextMenuStrip();

            headerItem = new ToolStripMenuItem("FuryCube G3");
            headerItem.Enabled = false;
            menu.Items.Add(headerItem);
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem ov = new ToolStripMenuItem("Оверлей");
            ovAlways = new ToolStripMenuItem("Показывать всегда", null, (s, e) => SetOverlayMode("always"));
            ovLow = new ToolStripMenuItem("Только при низком заряде (≤" + threshold + "%)", null, (s, e) => SetOverlayMode("low"));
            ovOff = new ToolStripMenuItem("Выключен", null, (s, e) => SetOverlayMode("off"));
            ov.DropDownItems.Add(ovAlways);
            ov.DropDownItems.Add(ovLow);
            ov.DropDownItems.Add(ovOff);
            menu.Items.Add(ov);

            ToolStripMenuItem pos = new ToolStripMenuItem("Положение оверлея");
            AddCorner(pos, "TL", "Слева сверху");
            AddCorner(pos, "TR", "Справа сверху");
            AddCorner(pos, "BL", "Слева снизу");
            AddCorner(pos, "BR", "Справа снизу");
            menu.Items.Add(pos);

            autoItem = new ToolStripMenuItem("Запускать вместе с Windows", null, (s, e) => { SetAutostart(!GetAutostart()); RefreshChecks(); });
            menu.Items.Add(autoItem);

            menu.Items.Add(new ToolStripMenuItem("Диагностика", null, (s, e) => ShowDiag()));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Выход", null, (s, e) => ExitApp()));

            RefreshChecks();
        }

        void AddCorner(ToolStripMenuItem parent, string code, string title)
        {
            string c = code;
            ToolStripMenuItem it = new ToolStripMenuItem(title, null, (s, e) => { corner = c; SaveSettings(); RefreshChecks(); UpdateUi(true); });
            cornerItems[code] = it;
            parent.DropDownItems.Add(it);
        }

        void SetOverlayMode(string mode)
        {
            overlayMode = mode;
            SaveSettings();
            RefreshChecks();
            UpdateUi(true);
        }

        void RefreshChecks()
        {
            ovAlways.Checked = overlayMode == "always";
            ovLow.Checked = overlayMode == "low";
            ovOff.Checked = overlayMode == "off";
            foreach (KeyValuePair<string, ToolStripMenuItem> kv in cornerItems) kv.Value.Checked = kv.Key == corner;
            autoItem.Checked = GetAutostart();
        }

        bool GetAutostart()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                {
                    return k != null && k.GetValue(RunName) != null;
                }
            }
            catch (Exception) { return false; }
        }

        void SetAutostart(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (on) k.SetValue(RunName, "wscript.exe \"" + Path.Combine(dir, "FuryBattery.vbs") + "\"");
                    else k.DeleteValue(RunName, false);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Не удалось изменить автозапуск: " + ex.Message, "FuryBattery");
            }
        }

        void LoadSettings()
        {
            try
            {
                if (!File.Exists(settingsPath)) return;
                foreach (string line in File.ReadAllLines(settingsPath))
                {
                    int i = line.IndexOf('=');
                    if (i <= 0) continue;
                    string k = line.Substring(0, i).Trim();
                    string v = line.Substring(i + 1).Trim();
                    if (k == "overlay" && (v == "always" || v == "low" || v == "off")) overlayMode = v;
                    else if (k == "corner" && (v == "TL" || v == "TR" || v == "BL" || v == "BR")) corner = v;
                    else if (k == "threshold")
                    {
                        int t;
                        if (int.TryParse(v, out t) && t > 0 && t < 100) threshold = t;
                    }
                }
            }
            catch (Exception) { }
        }

        void SaveSettings()
        {
            try
            {
                File.WriteAllLines(settingsPath, new string[] { "overlay=" + overlayMode, "corner=" + corner, "threshold=" + threshold });
            }
            catch (Exception) { }
        }

        void ShowDiag()
        {
            StringBuilder sb = new StringBuilder();
            lock (reader.Lock)
            {
                sb.AppendLine("Заряд: " + (reader.Battery < 0 ? "нет данных" : reader.Battery + "%"));
                sb.AppendLine("Последний пакет заряда: " + (reader.LastRaw == "" ? "не было" : reader.LastRaw));
                sb.AppendLine("Получен: " + (reader.LastSeen == DateTime.MinValue ? "никогда" : reader.LastSeen.ToString("HH:mm:ss")));
                sb.AppendLine("Байт состояния: " + reader.State);
                sb.AppendLine("Последний любой пакет: " + (reader.LastAnyRaw == "" ? "не было" : reader.LastAnyRaw));
                sb.AppendLine();
                sb.AppendLine("Журнал:");
                foreach (string s in reader.Log) sb.AppendLine(s);
            }
            string text = sb.ToString();
            try { Clipboard.SetText(text); } catch (Exception) { }
            MessageBox.Show(text + "\n(Этот текст уже скопирован — можно вставить его в чат.)", "FuryBattery — диагностика");
        }

        void ExitApp()
        {
            uiTimer.Stop();
            scanTimer.Stop();
            tray.Visible = false;
            tray.Dispose();
            overlay.Close();
            if (lastHicon != IntPtr.Zero) DestroyIcon(lastHicon);
            ExitThread();
        }
    }

    public static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        static Mutex mutex;

        public static void Run(string dir)
        {
            bool created;
            mutex = new Mutex(true, "Local\\FuryBatteryTray", out created);
            if (!created)
            {
                MessageBox.Show("FuryBattery уже запущена — значок в трее рядом с часами.", "FuryBattery");
                return;
            }
            try { SetProcessDPIAware(); } catch (Exception) { }
            Application.EnableVisualStyles();
            Application.Run(new TrayApp(dir));
            GC.KeepAlive(mutex);
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp -ErrorAction Stop
    [FuryBattery.Program]::Run($PSScriptRoot)
}
catch {
    $msg = $_.Exception.Message
    try { Set-Content -Path (Join-Path $PSScriptRoot 'FuryBattery-error.txt') -Value ($_ | Out-String) -Encoding UTF8 } catch { }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Ошибка запуска FuryBattery:`n`n$msg`n`nПодробности в файле FuryBattery-error.txt рядом с программой.", "FuryBattery") | Out-Null
}
