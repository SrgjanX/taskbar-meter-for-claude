#Requires -Version 5.1
<#
.SYNOPSIS
  Claude Taskbar Widget - an unofficial Windows widget that shows your Claude plan
  limits (session + weekly) as a small pill on the taskbar.

.DESCRIPTION
  Reads the OAuth login that Claude Code saves on this PC
  (%USERPROFILE%\.claude\.credentials.json) and polls
  https://api.anthropic.com/api/oauth/usage every 3 minutes - the same data
  Claude Code's /usage command shows. That endpoint is undocumented, so it may
  change; run with -DumpJson to see what it currently returns.

  Left-drag to move the pill. Right-click for options. Double-click opens the
  usage page on claude.ai.

.PARAMETER DumpJson
  Print the raw API response and exit (for troubleshooting).

.PARAMETER Autostart
  On  = start the pill automatically when you sign in to Windows.
  Off = remove that.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\claude-taskbar-widget.ps1
#>
param(
  [switch]$DumpJson,
  [ValidateSet('On', 'Off')][string]$Autostart
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ('ClaudeTaskbarWidgetNative' -as [type])) {
  Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ClaudeTaskbarWidgetNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, int wp, int lp);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
  [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  struct RECT { public int Left, Top, Right, Bottom; }

  public static void KeepOnTop(IntPtr h) {
    // HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
  }

  // True when the foreground window covers the whole screen (video, game, slideshow).
  public static bool ForegroundIsFullscreen(int l, int t, int r, int b, IntPtr self) {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero || h == self || h == GetShellWindow() || h == GetDesktopWindow()) return false;
    var sb = new StringBuilder(256);
    GetClassName(h, sb, 256);
    string c = sb.ToString();
    if (c == "WorkerW" || c == "Progman" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
    RECT rc;
    if (!GetWindowRect(h, out rc)) return false;
    return rc.Left <= l && rc.Top <= t && rc.Right >= r && rc.Bottom >= b;
  }
}
"@
}

# ---------------------------------------------------------------- settings ---
$script:CfgDir  = Join-Path $env:APPDATA 'ClaudeTaskbarWidget'
$script:CfgFile = Join-Path $script:CfgDir 'settings.json'
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Taskbar Widget.lnk'

function Read-Settings {
  $s = [pscustomobject]@{ X = $null; Y = $null; Locked = $false }
  if (Test-Path $script:CfgFile) {
    try {
      $j = Get-Content $script:CfgFile -Raw | ConvertFrom-Json
      if ($null -ne $j.X) { $s.X = [int]$j.X }
      if ($null -ne $j.Y) { $s.Y = [int]$j.Y }
      if ($null -ne $j.Locked) { $s.Locked = [bool]$j.Locked }
    } catch { }   # unreadable settings file: fall back to defaults
  }
  return $s
}

function Save-Settings {
  try {
    if (-not (Test-Path $script:CfgDir)) { New-Item -ItemType Directory -Path $script:CfgDir | Out-Null }
    $script:Settings | ConvertTo-Json | Set-Content -Path $script:CfgFile -Encoding UTF8
  } catch { }   # saving the position is best-effort
}

function Set-Autostart([bool]$On) {
  if ($On) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($script:StartupLnk)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = Split-Path $PSCommandPath
    $lnk.WindowStyle = 7   # minimized
    $lnk.Description = 'Claude Taskbar Widget'
    $lnk.Save()
  } else {
    Remove-Item $script:StartupLnk -ErrorAction SilentlyContinue
  }
}

# --------------------------------------------------------------------- API ---
function Get-ClaudeToken {
  $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
  $file = Join-Path $dir '.credentials.json'
  if (-not (Test-Path $file)) { throw 'NOLOGIN' }
  $c = Get-Content $file -Raw | ConvertFrom-Json
  $tok = $c.claudeAiOauth.accessToken
  if (-not $tok) { throw 'NOLOGIN' }
  return $tok
}

function Invoke-UsageApi {
  $headers = @{
    'Authorization'  = "Bearer $(Get-ClaudeToken)"
    'anthropic-beta' = 'oauth-2025-04-20'
    'User-Agent'     = 'claude-taskbar-widget/1.0'
  }
  Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method Get -TimeoutSec 12
}

function Get-HttpCode($err) {
  try { if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode } } catch { }   # no HTTP status (e.g. network error)
  return $null
}

function Get-ResetTime($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [datetime]) { return $v.ToLocalTime() }               # PowerShell 7 auto-converts dates
  if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
    $n = [double]$v; if ($n -gt 1e12) { $n = $n / 1000 }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$n).LocalDateTime
  }
  try { return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

# Turns the API response into a flat list of limit windows.
# Handles both the older flat keys (five_hour, seven_day, ...) and the newer
# "limits" array, whichever the endpoint returns.
function ConvertTo-Windows($r) {
  $out = New-Object System.Collections.ArrayList
  $flat = [ordered]@{
    five_hour        = @('session', 'Session')
    seven_day        = @('week',    'Week')
    seven_day_opus   = @('model',   'Week (Opus)')
    seven_day_sonnet = @('model',   'Week (Sonnet)')
  }
  foreach ($k in $flat.Keys) {
    $p = $r.$k
    if ($p -and $null -ne $p.utilization) {
      [void]$out.Add([pscustomobject]@{ Kind = $flat[$k][0]; Label = $flat[$k][1]; Pct = [double]$p.utilization; Reset = (Get-ResetTime $p.resets_at) })
    }
  }
  if ($out.Count -eq 0 -and $r.limits) {
    foreach ($l in @($r.limits)) {
      if ($null -eq $l.utilization) { continue }
      $model = $null
      if ($l.scope -and $l.scope.model) {
        $model = $l.scope.model.display_name
        if (-not $model) { $model = $l.scope.model.name }
      }
      $id = [string](@($l.type, $l.kind, $l.window, $l.name, $l.id, $l.label, $l.display_name) | Where-Object { $_ } | Select-Object -First 1)
      if ($model)                                  { $kind = 'model';   $label = "Week ($model)" }
      elseif ($id -match 'five|5h|session|hour')   { $kind = 'session'; $label = 'Session' }
      elseif ($id -match 'seven|7d|week')          { $kind = 'week';    $label = 'Week' }
      else {
        $kind = 'other'
        $label = if ($l.display_name) { [string]$l.display_name } elseif ($id) { $id } else { 'Limit' }
      }
      $resetRaw = @($l.resets_at, $l.reset_at, $l.resetsAt) | Where-Object { $_ } | Select-Object -First 1
      [void]$out.Add([pscustomobject]@{ Kind = $kind; Label = $label; Pct = [double]$l.utilization; Reset = (Get-ResetTime $resetRaw) })
    }
  }
  return , $out
}

function Format-Remaining($dt) {
  if ($null -eq $dt) { return '' }
  $ts = $dt - (Get-Date)
  if ($ts.TotalMinutes -le 0) { return 'now' }
  if ($ts.TotalDays -ge 1)  { return ('{0}d {1}h' -f [int][math]::Floor($ts.TotalDays), $ts.Hours) }
  if ($ts.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes) }
  return ('{0}m' -f [int][math]::Ceiling($ts.TotalMinutes))
}

# ---------------------------------------------------------- one-shot modes ---
if ($DumpJson) {
  try { Invoke-UsageApi | ConvertTo-Json -Depth 10 }
  catch {
    if ($_.Exception.Message -eq 'NOLOGIN') { Write-Host 'No Claude Code login found. Install Claude Code and run "claude" to sign in.' }
    else { Write-Host "Request failed (HTTP $(Get-HttpCode $_)): $($_.Exception.Message)" }
  }
  return
}
if ($Autostart) {
  Set-Autostart ($Autostart -eq 'On')
  Write-Host "Start with Windows: $Autostart"
  return
}

# ---------------------------------------------------------- single instance ---
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeTaskbarWidget', [ref]$created)
if (-not $created) { return }

# Hide the console window this script was started from.
$console = [ClaudeTaskbarWidgetNative]::GetConsoleWindow()
if ($console -ne [IntPtr]::Zero) { [void][ClaudeTaskbarWidgetNative]::ShowWindow($console, 0) }

[void][ClaudeTaskbarWidgetNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

$g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:S = $g0.DpiX / 96.0
$g0.Dispose()
function Px([double]$v) { [int][math]::Round($v * $script:S) }

# ------------------------------------------------------------------- state ---
$script:Settings  = Read-Settings
$script:Windows   = New-Object System.Collections.ArrayList
$script:Extra     = $null
$script:LastOk    = $null
$script:Err       = $null       # short text shown on the pill when there is no data
$script:ErrDetail = $null
$script:Stale     = $false
$script:Tick      = 0
$script:NextFetch = 0           # in minutes-ticks
$script:Segments  = @()
$script:HiddenForFullscreen = $false

$script:FLabel = New-Object Drawing.Font('Segoe UI', 8)
$script:FValue = New-Object Drawing.Font('Segoe UI Semibold', 9)
$script:TF = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::SingleLine

$script:CBack  = [Drawing.Color]::FromArgb(38, 40, 58)
$script:CEdge  = [Drawing.Color]::FromArgb(70, 74, 100)
$script:CLabel = [Drawing.Color]::FromArgb(170, 174, 196)
$script:CText  = [Drawing.Color]::FromArgb(240, 240, 245)
$script:CGood  = [Drawing.Color]::FromArgb(126, 226, 168)
$script:CWarn  = [Drawing.Color]::FromArgb(245, 194, 107)
$script:CBad   = [Drawing.Color]::FromArgb(255, 123, 114)
$script:CAccent = [Drawing.Color]::FromArgb(217, 119, 87)

function Get-PctColor([double]$p) {
  if ($p -ge 80) { return $script:CBad }
  if ($p -ge 50) { return $script:CWarn }
  return $script:CGood
}

# ------------------------------------------------------------------- data ---
function Update-Segments {
  $segs = @()
  if ($script:Windows.Count -gt 0) {
    $sess = $script:Windows | Where-Object { $_.Kind -eq 'session' } | Select-Object -First 1
    $week = $script:Windows | Where-Object { $_.Kind -eq 'week' } | Select-Object -First 1
    if (-not $sess) { $sess = $script:Windows[0] }
    if (-not $week -and $script:Windows.Count -gt 1) { $week = $script:Windows | Where-Object { $_ -ne $sess } | Select-Object -First 1 }
    foreach ($w in @($sess, $week)) {
      if (-not $w) { continue }
      $short = switch ($w.Kind) { 'session' { '5h' } 'week' { '7d' } default { $w.Label } }
      $segs += [pscustomobject]@{
        Top   = $short
        Value = ('{0:0}%' -f $w.Pct)
        Pct   = [math]::Max(0, [math]::Min(100, $w.Pct))
      }
    }
  } else {
    $segs += [pscustomobject]@{ Top = 'Claude'; Value = $(if ($script:Err) { $script:Err } else { '...' }); Pct = $null }
  }
  $script:Segments = $segs
}

function Update-Tooltip {
  $lines = @('Claude plan usage')
  foreach ($w in $script:Windows) {
    $line = '{0}: {1:0}% used' -f $w.Label, $w.Pct
    if ($w.Reset) { $line += ' - resets in {0} ({1})' -f (Format-Remaining $w.Reset), $w.Reset.ToString('ddd HH:mm') }
    $lines += $line
  }
  $x = $script:Extra
  if ($x -and $x.is_enabled) {
    $used = if ($null -ne $x.used_credits) { [double]$x.used_credits / 100 } else { 0 }
    if ($null -ne $x.monthly_limit) { $lines += ('Extra usage: ${0:0.00} of ${1:0.00} this month' -f $used, ([double]$x.monthly_limit / 100)) }
    else { $lines += ('Extra usage: ${0:0.00} this month' -f $used) }
  }
  if ($script:Err -and $script:ErrDetail) { $lines += ''; $lines += "$($script:Err): $($script:ErrDetail)" }
  if ($script:LastOk) {
    $lines += ''
    $lines += 'Updated ' + $script:LastOk.ToString('HH:mm') + $(if ($script:Stale) { ' (could not refresh since)' } else { '' })
  }
  $lines += 'Drag to move - right-click for options'
  $script:Tip.SetToolTip($script:Form, ($lines -join "`n"))
}

function Update-Usage {
  try {
    $r = Invoke-UsageApi
    $script:Windows   = ConvertTo-Windows $r
    $script:Extra     = $r.extra_usage
    $script:LastOk    = Get-Date
    $script:Err       = $null
    $script:ErrDetail = $null
    $script:Stale     = $false
    $script:NextFetch = $script:Tick + 3
    if ($script:Windows.Count -eq 0) { $script:Err = 'No data'; $script:ErrDetail = 'The usage endpoint returned no limits. Run the script with -DumpJson to inspect it.' }
  } catch {
    $code = Get-HttpCode $_
    $script:Stale = $true
    if ($_.Exception.Message -eq 'NOLOGIN') {
      $script:Windows.Clear()
      $script:Err = 'Not signed in'; $script:ErrDetail = 'Install Claude Code and run "claude" once to sign in with your Claude account.'
      $script:NextFetch = $script:Tick + 2
    } elseif ($code -eq 401 -or $code -eq 403) {
      $script:Windows.Clear()
      $script:Err = 'Login expired'; $script:ErrDetail = 'Open Claude Code once so it refreshes its login; the pill picks it up automatically.'
      $script:NextFetch = $script:Tick + 2
    } elseif ($code -eq 429) {
      $script:Err = 'Rate limited'; $script:ErrDetail = 'Waiting 10 minutes before trying again.'
      $script:NextFetch = $script:Tick + 10
    } else {
      $script:Err = 'Offline'; $script:ErrDetail = $_.Exception.Message
      $script:NextFetch = $script:Tick + 2
    }
  }
  Update-Segments
  Update-Layout
  Update-Tooltip
  $script:Form.Invalidate()
}

# ----------------------------------------------------------------- layout ---
function Get-TaskbarRect {
  $scr = [Windows.Forms.Screen]::PrimaryScreen
  $b = $scr.Bounds; $w = $scr.WorkingArea
  if ($w.Bottom -lt $b.Bottom) { return New-Object Drawing.Rectangle($b.Left, $w.Bottom, $b.Width, ($b.Bottom - $w.Bottom)) }
  $h = Px 48   # auto-hidden taskbar: assume the standard height
  return New-Object Drawing.Rectangle($b.Left, ($b.Bottom - $h), $b.Width, $h)
}

function New-RoundPath([Drawing.RectangleF]$r, [single]$rad) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $rad * 2
  $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
  $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
  $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
  $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function Update-Layout {
  $tb = Get-TaskbarRect
  $h = Px 26
  $pad = Px 9; $dot = Px 6; $gap = Px 10
  $w = $pad + $dot + (Px 7)
  $i = 0
  foreach ($s in $script:Segments) {
    $tw = [Windows.Forms.TextRenderer]::MeasureText($s.Top, $script:FLabel, [Drawing.Size]::Empty, $script:TF).Width
    $vw = [Windows.Forms.TextRenderer]::MeasureText($s.Value, $script:FValue, [Drawing.Size]::Empty, $script:TF).Width
    $s | Add-Member -NotePropertyName LabelWidth -NotePropertyValue $tw -Force
    $s | Add-Member -NotePropertyName Width -NotePropertyValue ($tw + (Px 4) + $vw) -Force
    $w += $s.Width
    if ($i -gt 0) { $w += $gap }
    $i++
  }
  $w += $pad

  $f = $script:Form
  if ($f.Width -ne $w -or $f.Height -ne $h) {
    $f.Size = New-Object Drawing.Size($w, $h)
    $old = $f.Region
    $path = New-RoundPath (New-Object Drawing.RectangleF(0, 0, $w, $h)) ([single](Px 6))
    $f.Region = New-Object Drawing.Region($path)
    $path.Dispose()
    if ($old) { $old.Dispose() }
  }

  if ($null -eq $script:Settings.X) {
    $f.Location = New-Object Drawing.Point(($tb.Left + (Px 150)), ($tb.Top + [int](($tb.Height - $h) / 2)))
  }
}

function Set-InitialPosition {
  $s = $script:Settings
  if ($null -ne $s.X -and $null -ne $s.Y) {
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($vs.Contains($s.X + 5, $s.Y + 5)) {
      $script:Form.Location = New-Object Drawing.Point($s.X, $s.Y)
      return
    }
    $s.X = $null; $s.Y = $null
  }
  Update-Layout
}

# ------------------------------------------------------------------- form ---
$form = New-Object Windows.Forms.Form
$script:Form = $form
$form.Text = 'Claude Taskbar Widget'
$form.FormBorderStyle = 'None'
$form.MaximizeBox = $false   # otherwise a double-click on the drag area maximizes the pill
$form.MinimizeBox = $false
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.AutoScaleMode = 'None'
$form.BackColor = $script:CBack
$form.Size = New-Object Drawing.Size((Px 160), (Px 38))
$form.Cursor = [Windows.Forms.Cursors]::Default
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true, $null)

$script:Tip = New-Object Windows.Forms.ToolTip
$script:Tip.InitialDelay = 300
$script:Tip.AutoPopDelay = 20000

$form.Add_Paint({
  param($src, $e)
  $g = $e.Graphics
  $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $f = $script:Form
  $W = $f.ClientSize.Width; $H = $f.ClientSize.Height

  # border
  $edge = New-RoundPath (New-Object Drawing.RectangleF(0.5, 0.5, ($W - 1.5), ($H - 1.5))) ([single](Px 6))
  $pen = New-Object Drawing.Pen($script:CEdge, 1)
  $g.DrawPath($pen, $edge); $pen.Dispose(); $edge.Dispose()

  # status dot
  $pad = Px 9; $dot = Px 6
  $dotColor = if ($script:Windows.Count -eq 0 -and $script:Err) { $script:CBad } elseif ($script:Stale) { $script:CLabel } else { $script:CAccent }
  $br = New-Object Drawing.SolidBrush($dotColor)
  $g.FillEllipse($br, $pad, [int](($H - $dot) / 2), $dot, $dot); $br.Dispose()

  # one line: "5h 23%  7d 14%" - labels and values share a vertical center
  $ly = [int](($H - $script:FLabel.Height) / 2)
  $vy = [int](($H - $script:FValue.Height) / 2)
  $x = $pad + $dot + (Px 7)
  $i = 0
  foreach ($s in $script:Segments) {
    if ($i -gt 0) { $x += (Px 10) }
    [Windows.Forms.TextRenderer]::DrawText($g, $s.Top, $script:FLabel, (New-Object Drawing.Point($x, $ly)), $script:CLabel, $script:TF)
    $vc = if ($null -ne $s.Pct) { Get-PctColor $s.Pct } else { $script:CText }
    [Windows.Forms.TextRenderer]::DrawText($g, $s.Value, $script:FValue, (New-Object Drawing.Point(($x + $s.LabelWidth + (Px 4)), $vy)), $vc, $script:TF)
    $x += $s.Width
    $i++
  }
})

# double-click opens the usage page; left-drag moves the pill
$form.Add_MouseDown({
  param($src, $e)
  if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
  if ($e.Clicks -ge 2) { Start-Process 'https://claude.ai/settings/usage'; return }
  if (-not $script:Settings.Locked) {
    [void][ClaudeTaskbarWidgetNative]::ReleaseCapture()
    [void][ClaudeTaskbarWidgetNative]::SendMessage($script:Form.Handle, 0xA1, 2, 0)   # WM_NCLBUTTONDOWN, HTCAPTION
    $script:Settings.X = $script:Form.Left
    $script:Settings.Y = $script:Form.Top
    Save-Settings
  }
})

# right-click menu
$menu = New-Object Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miOpen    = $menu.Items.Add('Open usage page')
[void]$menu.Items.Add('-')
$miLock    = $menu.Items.Add('Lock position')
$miReset   = $menu.Items.Add('Reset position')
$miAuto    = $menu.Items.Add('Start with Windows')
[void]$menu.Items.Add('-')
$miExit    = $menu.Items.Add('Exit')

$miRefresh.Add_Click({ Update-Usage })
$miOpen.Add_Click({ Start-Process 'https://claude.ai/settings/usage' })
$miLock.Add_Click({ $script:Settings.Locked = -not $script:Settings.Locked; Save-Settings })
$miReset.Add_Click({ $script:Settings.X = $null; $script:Settings.Y = $null; Save-Settings; Update-Layout })
$miAuto.Add_Click({ Set-Autostart (-not (Test-Path $script:StartupLnk)) })
$miExit.Add_Click({ $script:Form.Close() })
$menu.Add_Opening({
  $miLock.Checked = [bool]$script:Settings.Locked
  $miAuto.Checked = Test-Path $script:StartupLnk
})
$form.ContextMenuStrip = $menu

# keep the pill above the taskbar, and step aside for fullscreen apps
$topTimer = New-Object Windows.Forms.Timer
$topTimer.Interval = 1000
$topTimer.Add_Tick({
  $f = $script:Form
  $scr = [Windows.Forms.Screen]::FromControl($f).Bounds
  $full = [ClaudeTaskbarWidgetNative]::ForegroundIsFullscreen($scr.Left, $scr.Top, $scr.Right, $scr.Bottom, $f.Handle)
  if ($full) {
    if (-not $script:HiddenForFullscreen) { [void][ClaudeTaskbarWidgetNative]::ShowWindow($f.Handle, 0); $script:HiddenForFullscreen = $true }   # SW_HIDE
  } else {
    # SW_SHOWNOACTIVATE: reappear without stealing focus from the app you're using
    if ($script:HiddenForFullscreen) { [void][ClaudeTaskbarWidgetNative]::ShowWindow($f.Handle, 4); $script:HiddenForFullscreen = $false }
    [ClaudeTaskbarWidgetNative]::KeepOnTop($f.Handle)
  }
})

# once a minute: update countdowns, and fetch every 3 minutes (or after backoff)
$minTimer = New-Object Windows.Forms.Timer
$minTimer.Interval = 60000
$minTimer.Add_Tick({
  $script:Tick++
  if ($script:Tick -ge $script:NextFetch) { Update-Usage }
  else { Update-Segments; Update-Layout; Update-Tooltip; $script:Form.Invalidate() }
})

$form.Add_Shown({
  Set-InitialPosition
  Update-Usage
  $topTimer.Start()
  $minTimer.Start()
})

$form.Add_FormClosed({
  $topTimer.Stop(); $minTimer.Stop()
  try { $script:Mutex.ReleaseMutex() } catch { }   # already released
})

Update-Segments
[Windows.Forms.Application]::Run($form)
