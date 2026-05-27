#Requires -Version 5.1
<#
  Transparent WinForms danmaku overlay on mpv window.
  File IPC: node appends JSONL, Timer drains and paints.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 把任意"可能是 IntPtr"的值安全转成 IntPtr；null / 类型不符 / 异常都映射到 Zero。
# 必须定义在顶层，因为 timer tick scriptblock 是延迟在 message loop 里执行的，
# 函数作用域随 Start-DanmakuOverlay 返回会被销毁。
function ConvertTo-SafeHwnd {
    param($Value)
    if ($null -eq $Value) { return [IntPtr]::Zero }
    if ($Value -is [IntPtr]) { return $Value }
    try { return [IntPtr]$Value } catch { return [IntPtr]::Zero }
}

if (-not ('BiliWin32' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class BiliWin32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_TRANSPARENT = 0x20;
  public const int WS_EX_LAYERED = 0x80000;
  public const int WS_EX_NOACTIVATE = 0x08000000;
  public const int WS_EX_TOOLWINDOW = 0x80;
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public const uint SWP_NOMOVE = 0x2;
  public const uint SWP_NOSIZE = 0x1;
  public const uint SWP_NOACTIVATE = 0x10;
  public const uint SWP_SHOWWINDOW = 0x40;

  public static IntPtr FindMainWindowByPid(uint pid) {
    IntPtr best = IntPtr.Zero;
    int bestArea = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      int w = r.Right - r.Left; int hh = r.Bottom - r.Top;
      int area = w * hh;
      if (w < 100 || hh < 100) return true;
      // Prefer the largest visible top-level window owned by this PID.
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
"@
}

function Start-DanmakuOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutFile,
        [int]$MpvPid = 0,
        [float]$Speed = 10.0,
        [float]$Rate = 0,
        [string]$Color = ''
    )

    if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
        Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Script 'Overlay' -Message ("Start-DanmakuOverlay MpvPid={0} OutFile={1}" -f $MpvPid, $OutFile)
    }

    # mpv 退出时 timer 可能竞态触发 P/Invoke 类型转换异常。把这些非致命异常
    # 路由到日志而不是弹出 WinForms "未处理异常" 对话框。
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
    } catch { }
    $script:DanmakuThreadExHandler = [System.Threading.ThreadExceptionEventHandler] {
        param($s, $e)
        if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
            Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Script 'Overlay' `
                -Message ("ThreadException suppressed: {0}" -f $e.Exception.Message)
        }
    }
    try {
        [System.Windows.Forms.Application]::remove_ThreadException($script:DanmakuThreadExHandler)
    } catch { }
    [System.Windows.Forms.Application]::add_ThreadException($script:DanmakuThreadExHandler)
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $fs = [System.IO.File]::Open(
        $OutFile,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $defaultW = [Math]::Min(1280, $screen.Width - 80)
    $defaultH = [Math]::Min(720, $screen.Height - 80)
    $defaultX = $screen.Left + [int](($screen.Width - $defaultW) / 2)
    $defaultY = $screen.Top + [int](($screen.Height - $defaultH) / 2)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BiliDanmakuOverlay'
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = [System.Drawing.Color]::Magenta
    $form.TransparencyKey = [System.Drawing.Color]::Magenta
    $form.SetBounds($defaultX, $defaultY, $defaultW, $defaultH)
    # DoubleBuffered is protected; flip via SetStyle reflection to avoid flicker
    try {
        $setStyle = $form.GetType().GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic, Instance')
        $opt = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor [System.Windows.Forms.ControlStyles]::UserPaint
        $setStyle.Invoke($form, @([System.Windows.Forms.ControlStyles]$opt, $true)) | Out-Null
    } catch { }

    $state = [pscustomobject]@{
        Reader            = $reader
        FileStream        = $fs
        MpvPid            = $MpvPid
        MpvHwnd           = [IntPtr]::Zero
        Lines             = New-Object System.Collections.Generic.List[object]
        Font              = New-Object System.Drawing.Font('Microsoft YaHei UI', 22, [System.Drawing.FontStyle]::Bold)
        LaneHeight        = 42
        LaneCount         = 14
        NextLane          = 0
        Speed             = $Speed
        Timer             = $null
        Measure           = (New-Object System.Drawing.Bitmap 1, 1)
        LastDataTick      = 0
        TickCount         = 0
        LastDanmakuTick   = 0
        RateTicks         = [int]($Rate * 25)
        OverrideColor     = $(if ($Color) { $colorObj = [System.Drawing.Color]::White; try { $hex = $Color.TrimStart('#'); $r = [Convert]::ToInt32($hex.Substring(0,2), 16); $gv = [Convert]::ToInt32($hex.Substring(2,2), 16); $b = [Convert]::ToInt32($hex.Substring(4,2), 16); [System.Drawing.Color]::FromArgb(255, $r, $gv, $b) } catch { $null } } else { $null })
        MpvMissingTicks   = 0
        TopmostEveryTicks = 25  # re-assert topmost every ~1s
    }
    $form.Tag = $state

    $form.Add_Paint({
        param($sender, $e)
        $st = $sender.Tag
        $g = $e.Graphics
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $shadowColor = [System.Drawing.Color]::FromArgb(220, 0, 0, 0)
        $shadow = New-Object System.Drawing.SolidBrush $shadowColor
        try {
            foreach ($ln in $st.Lines) {
                $g.DrawString($ln.Text, $st.Font, $shadow, [single]($ln.X + 2), [single]($ln.Y + 2))
                $brush = New-Object System.Drawing.SolidBrush $ln.Color
                try { $g.DrawString($ln.Text, $st.Font, $brush, [single]$ln.X, [single]$ln.Y) }
                finally { $brush.Dispose() }
            }
        } finally { $shadow.Dispose() }
    })

    $form.Add_Shown({
        $f = $this
        try {
            $ex = [BiliWin32]::GetWindowLong($f.Handle, [BiliWin32]::GWL_EXSTYLE)
            $ex = $ex -bor [BiliWin32]::WS_EX_LAYERED -bor [BiliWin32]::WS_EX_TRANSPARENT -bor [BiliWin32]::WS_EX_NOACTIVATE -bor [BiliWin32]::WS_EX_TOOLWINDOW
            [void][BiliWin32]::SetWindowLong($f.Handle, [BiliWin32]::GWL_EXSTYLE, $ex)
            [void][BiliWin32]::SetWindowPos($f.Handle, [BiliWin32]::HWND_TOPMOST, 0, 0, 0, 0,
                [BiliWin32]::SWP_NOMOVE -bor [BiliWin32]::SWP_NOSIZE -bor [BiliWin32]::SWP_NOACTIVATE -bor [BiliWin32]::SWP_SHOWWINDOW)
        } catch { }
    })

    $form.Add_Load({
        $f = $this
        $st = $f.Tag

        if ($st.MpvPid -gt 0) {
            try {
                $p = Get-Process -Id $st.MpvPid -ErrorAction SilentlyContinue
                $h = [IntPtr]::Zero
                if ($p) {
                    try { $h = [IntPtr]$p.MainWindowHandle } catch { $h = [IntPtr]::Zero }
                }
                if ($h -eq [IntPtr]::Zero) {
                    $h = [BiliWin32]::FindMainWindowByPid([uint32]$st.MpvPid)
                }
                $st.MpvHwnd = $h
            } catch { $st.MpvHwnd = [IntPtr]::Zero }
        }

        # Seed a banner so user knows overlay is alive
        [void]$st.Lines.Add([pscustomobject]@{
            Text  = '弹幕已就绪，等待消息…'
            Color = [System.Drawing.Color]::FromArgb(255, 255, 230, 120)
            X     = [single]$f.ClientSize.Width
            Y     = [single]8
            W     = [single]300
        })

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 40
        $timer.Add_Tick({
            $form2 = $this.Tag
            $st2 = $form2.Tag

            $st2.TickCount++

            # 把当前 hwnd 安全转成 IntPtr；后续都用本地变量 $hwnd，避免 PSCustomObject
            # 弱类型字段在 P/Invoke 边界上被 PowerShell 推断成 string/null 触发崩溃。
            $hwnd = ConvertTo-SafeHwnd $st2.MpvHwnd
            $hwndAlive = $false
            if ($hwnd -ne [IntPtr]::Zero) {
                try { $hwndAlive = [BiliWin32]::IsWindow($hwnd) } catch { $hwndAlive = $false }
            }

            if ($st2.MpvPid -gt 0) {
                if (-not $hwndAlive) {
                    $alive = $null
                    try { $alive = Get-Process -Id $st2.MpvPid -ErrorAction SilentlyContinue } catch { }
                    if (-not $alive) {
                        $st2.MpvMissingTicks++
                        # mpv 进程消失短暂容忍 ~1 秒（用户切流时进程会重启），超过即关闭 overlay
                        if ($st2.MpvMissingTicks -gt 25) {
                            if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
                                Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Script 'Overlay' -Message 'mpv exited; closing overlay'
                            }
                            $this.Stop()
                            $form2.Close()
                            return
                        }
                    } else {
                        $st2.MpvMissingTicks = 0
                        $newH = [IntPtr]::Zero
                        try { $newH = [IntPtr]$alive.MainWindowHandle } catch { }
                        if ($newH -eq [IntPtr]::Zero) {
                            try { $newH = [BiliWin32]::FindMainWindowByPid([uint32]$st2.MpvPid) } catch { }
                        }
                        if ($newH -ne [IntPtr]::Zero) {
                            $st2.MpvHwnd = $newH
                            $hwnd = $newH
                            try { $hwndAlive = [BiliWin32]::IsWindow($hwnd) } catch { $hwndAlive = $false }
                        }
                    }
                } else {
                    $st2.MpvMissingTicks = 0
                }
            }

            # 跟随 mpv 窗口
            if ($hwndAlive) {
                $visible = $false; $iconic = $true
                try {
                    $visible = [BiliWin32]::IsWindowVisible($hwnd)
                    $iconic  = [BiliWin32]::IsIconic($hwnd)
                } catch { }
                if ($visible -and (-not $iconic)) {
                    $rc = New-Object BiliWin32+RECT
                    if ([BiliWin32]::GetWindowRect($hwnd, [ref]$rc)) {
                        $w = $rc.Right - $rc.Left
                        $h = $rc.Bottom - $rc.Top
                        if ($w -gt 100 -and $h -gt 100) {
                            if ($form2.Left -ne $rc.Left -or $form2.Top -ne $rc.Top -or $form2.Width -ne $w -or $form2.Height -ne $h) {
                                $form2.SetBounds($rc.Left, $rc.Top, $w, $h)
                            }
                        }
                    }
                }
            }

            # Re-assert topmost periodically (mpv fullscreen tends to steal z-order)
            if (($st2.TickCount % $st2.TopmostEveryTicks) -eq 0) {
                try {
                    [void][BiliWin32]::SetWindowPos($form2.Handle, [BiliWin32]::HWND_TOPMOST, 0, 0, 0, 0,
                        [BiliWin32]::SWP_NOMOVE -bor [BiliWin32]::SWP_NOSIZE -bor [BiliWin32]::SWP_NOACTIVATE)
                } catch { }
            }

            # Drain JSONL
            $drained = 0
            try {
                while ($drained -lt 64) {
                    $line = $st2.Reader.ReadLine()
                    if ($null -eq $line) { break }
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $drained++
                    $st2.LastDataTick = $st2.TickCount
                    try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    $t = [string]$obj.type
                    if ($t -eq 'danmaku') {
                        $color = [System.Drawing.Color]::White
                        if ($st2.OverrideColor) {
                            $color = $st2.OverrideColor
                        } else {
                            try {
                                $hex = [string]$obj.color
                                if ($hex -and $hex.StartsWith('#') -and $hex.Length -ge 7) {
                                    $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
                                    $gv = [Convert]::ToInt32($hex.Substring(3, 2), 16)
                                    $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
                                    $color = [System.Drawing.Color]::FromArgb(255, $r, $gv, $b)
                                }
                            } catch { }
                        }
                        $text = [string]$obj.text
                        if (-not $text) { continue }

                        if ($st2.RateTicks -gt 0 -and $st2.LastDanmakuTick -gt 0) {
                            $gap = $st2.TickCount - $st2.LastDanmakuTick
                            if ($gap -lt $st2.RateTicks) { continue }
                        }
                        $st2.LastDanmakuTick = $st2.TickCount

                        $gtmp = [System.Drawing.Graphics]::FromImage($st2.Measure)
                        $sz = $gtmp.MeasureString($text, $st2.Font)
                        $gtmp.Dispose()

                        $lane = $st2.NextLane % $st2.LaneCount
                        $st2.NextLane++
                        $y = $lane * $st2.LaneHeight + 6

                        [void]$st2.Lines.Add([pscustomobject]@{
                            Text  = $text
                            Color = $color
                            X     = [single]$form2.ClientSize.Width
                            Y     = [single]$y
                            W     = [single]$sz.Width
                        })
                    } elseif (($t -eq 'system' -or $t -eq 'error') -and (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue)) {
                        $lvl = if ($t -eq 'error') { 'ERROR' } else { 'INFO' }
                        Write-BiliDiag -Level $lvl -Category 'DANMAKU' -Script 'Overlay' -Message ("[node/{0}] {1}" -f $t, ([string]$obj.message))
                    }
                }
            } catch {
                if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
                    Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Script 'Overlay' -Message ("drain error: {0}" -f $_.Exception.Message)
                }
            }

            # Move and cull
            $rm = $null
            foreach ($ln in $st2.Lines) {
                $ln.X = [single]($ln.X - $st2.Speed)
                if (($ln.X + $ln.W) -lt 0) {
                    if ($null -eq $rm) { $rm = New-Object System.Collections.Generic.List[object] }
                    [void]$rm.Add($ln)
                }
            }
            if ($null -ne $rm) {
                foreach ($ln in $rm) { [void]$st2.Lines.Remove($ln) }
            }

            $form2.Invalidate()
        })
        $timer.Tag = $f
        $st.Timer = $timer
        $timer.Start()
    })

    $form.Add_FormClosed({
        try {
            $st = $this.Tag
            if ($st.Timer) { $st.Timer.Stop(); $st.Timer.Dispose(); $st.Timer = $null }
            if ($st.Reader) { $st.Reader.Dispose() }
            if ($st.FileStream) { $st.FileStream.Dispose() }
            if ($st.Measure) { $st.Measure.Dispose() }
            if ($st.Font) { $st.Font.Dispose() }
        } catch { }
    })

    [System.Windows.Forms.Application]::Run($form)
}
