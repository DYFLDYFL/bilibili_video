#Requires -Version 5.1
<#
  Transparent WinForms danmaku overlay on mpv window.
  File IPC: node appends JSONL, Timer drains and paints.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('BiliWin32' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class BiliWin32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
"@
}

function Start-DanmakuOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutFile,
        [int]$MpvPid = 0,
        [float]$Speed = 10.0
    )

    if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
        Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Script 'Overlay' -Message ("Start-DanmakuOverlay MpvPid={0} OutFile={1}" -f $MpvPid, $OutFile)
    }

    # Must call SetUnhandledExceptionMode BEFORE EnableVisualStyles()
    # to avoid "只要在线程上创建了任何控件，则线程异常模式将不能再有任何更改"
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode('Automatic')
    } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $fs = [System.IO.File]::Open(
        $OutFile,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BiliDanmakuOverlay'
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = [System.Drawing.Color]::Magenta
    $form.TransparencyKey = [System.Drawing.Color]::Magenta
    $form.Width = 800
    $form.Height = 450
    $form.Location = New-Object System.Drawing.Point(0, 0)

    $state = [pscustomobject]@{
        Reader     = $reader
        FileStream = $fs
        MpvPid     = $MpvPid
        MpvHwnd    = [IntPtr]::Zero
        Lines      = New-Object System.Collections.Generic.List[object]
        Font       = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
        LaneHeight = 38
        LaneCount  = 12
        NextLane   = 0
        Speed      = $Speed
        Timer      = $null
        Measure    = (New-Object System.Drawing.Bitmap 1, 1)
        LastDataTick = 0
        TickCount    = 0
    }
    $form.Tag = $state

    $form.Add_Paint({
        param($sender, $e)
        $st = $sender.Tag
        $g = $e.Graphics
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        foreach ($ln in $st.Lines) {
            $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))
            $g.DrawString($ln.Text, $st.Font, $shadow, [single]($ln.X + 2), [single]($ln.Y + 2))
            $shadow.Dispose()
            $brush = New-Object System.Drawing.SolidBrush $ln.Color
            $g.DrawString($ln.Text, $st.Font, $brush, [single]$ln.X, [single]$ln.Y)
            $brush.Dispose()
        }
    })

    $form.Add_Load({
        $f = $this
        $st = $f.Tag

        if ($st.MpvPid -gt 0) {
            try {
                $p = Get-Process -Id $st.MpvPid -ErrorAction SilentlyContinue
                if ($p) { $st.MpvHwnd = [IntPtr]$p.MainWindowHandle }
            } catch { }
        }

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 40
        $timer.Add_Tick({
            $form2 = $this.Tag
            $st2 = $form2.Tag

            $st2.TickCount++

            if ($st2.MpvPid -gt 0) {
                $hwndOk = $false
                try { $hwndOk = ($st2.MpvHwnd -and [BiliWin32]::IsWindow($st2.MpvHwnd)) } catch { }
                if (-not $hwndOk) {
                    # HWND not resolved or mpv window gone — try to re-resolve
                    try {
                        $alive = Get-Process -Id $st2.MpvPid -ErrorAction SilentlyContinue
                        if (-not $alive) { $form2.Close(); return }
                        $st2.MpvHwnd = [IntPtr]$alive.MainWindowHandle
                    } catch { }
                }
            }

            $syncOk = $false
            try { $syncOk = ($st2.MpvHwnd -and [BiliWin32]::IsWindow($st2.MpvHwnd) -and [BiliWin32]::IsWindowVisible($st2.MpvHwnd)) } catch { }
            if ($syncOk) {
                $rc = New-Object BiliWin32+RECT
                if ([BiliWin32]::GetWindowRect($st2.MpvHwnd, [ref]$rc)) {
                    $w = $rc.Right - $rc.Left
                    $h = $rc.Bottom - $rc.Top
                    if ($w -gt 100 -and $h -gt 100) {
                        if ($form2.Left -ne $rc.Left -or $form2.Top -ne $rc.Top -or $form2.Width -ne $w -or $form2.Height -ne $h) {
                            $form2.SetBounds($rc.Left, $rc.Top, $w, $h)
                        }
                    }
                }
            }

            $drained = 0
            try {
                while ($drained -lt 50) {
                    $line = $st2.Reader.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line)) { break }
                    $drained++
                    $st2.LastDataTick = $st2.TickCount
                    try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    $t = [string]$obj.type
                    if ($t -eq 'danmaku') {
                        $color = [System.Drawing.Color]::White
                        try {
                            $hex = [string]$obj.color
                            if ($hex -and $hex.StartsWith('#') -and $hex.Length -eq 7) {
                                $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
                                $gv = [Convert]::ToInt32($hex.Substring(3, 2), 16)
                                $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
                                $color = [System.Drawing.Color]::FromArgb(255, $r, $gv, $b)
                            }
                        } catch { }
                        $text = [string]$obj.text
                        if (-not $text) { continue }

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

            # heartbeat timeout: if no data (including heartbeats) for 60s, node likely dead
            if ($st2.LastDataTick -gt 0 -and ($st2.TickCount - $st2.LastDataTick) -gt 1500) {
                if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
                    Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Script 'Overlay' -Message 'node heartbeat timeout; closing overlay'
                }
                $form2.Close()
                return
            }

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
