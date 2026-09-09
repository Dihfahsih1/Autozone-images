<#
.SYNOPSIS
  Self-contained ERPNext USB backup for a Windows laptop. No upload, no restore.
  Pulls ONE verified tar.gz from the VPS straight onto the external USB drive
  labelled BACKUP, keeps only the latest 3, permanently deletes the rest.

.USAGE
  1. Plug in the USB drive labelled BACKUP (any letter, we find it by label).
  2. Edit the CONFIG block below once (VPS ip/user/key, site name, db pass).
  3. Right-click > "Run with PowerShell"  — or from PowerShell:
       powershell -ExecutionPolicy Bypass -File .\windows_usb_backup.ps1
     First run:  .\windows_usb_backup.ps1 -InstallSchedule   # 3x daily tasks
     Manual run: .\windows_usb_backup.ps1                    # backup now
     Remove:     .\windows_usb_backup.ps1 -UninstallSchedule

  Scheduled times (daily): 08:00, 13:00, 18:00. Change $ScheduleTimes below.

.REQUIREMENTS
  - Windows 10/11 with OpenSSH Client (ssh + scp). Script checks and tells
    you how to install if missing.
  - SSH KEY auth to the VPS (no sshpass on Windows). Generate once with
    ssh-keygen and append the .pub to the VPS ~/.ssh/authorized_keys.
    Password auth will just prompt/hang, so key is required.
  - USB drive volume label must be exactly: BACKUP
#>
param(
  [switch]$InstallSchedule,
  [switch]$UninstallSchedule
)

$ErrorActionPreference = 'Stop'

# ============================ CONFIG — EDIT ME ============================
$Config = @{
  RemoteUser       = 'autopro'                        # VPS ssh user
  RemoteHost       = '185.27.135.97'                  # VPS ip/host
  RemotePort       = '2394'                           # VPS ssh port
  SshKey           = "$env:USERPROFILE\.ssh\id_ed25519"  # private key path
  SiteName         = 'accounting.autozonepro.org'
  DbContainer      = 'frappe_docker-db-1'
  BackendContainer = 'frappe_docker-backend-1'
  RemoteWorkDir    = '/home/autopro/frappe_docker'    # where docker-compose.yml lives

  UsbLabel      = 'BACKUP'            # exact volume label of the USB drive
  BackupSubDir  = 'erpnext_backups'   # <USB>:\erpnext_backups\
  KeepBackups   = 3                   # keep ONLY the latest 3, delete the rest
  ScheduleTimes = @('08:00','13:00','18:00')  # 3x daily
  SshTimeoutSec = 20
}
# ========================== END CONFIG =====================================

function Write-Log($msg, $color='White') {
  $ts = Get-Date -Format 'HH:mm:ss'
  Write-Host "[$ts] $msg" -ForegroundColor $color
}

function Get-BackupDrive {
  # Find USB by volume label, any letter (D:, E:, F: ...)
  $vol = Get-CimInstance Win32_Volume -Filter "Label = '$($Config.UsbLabel)'" -ErrorAction SilentlyContinue |
         Where-Object { $_.DriveLetter } | Select-Object -First 1
  if (-not $vol) {
    # Fallback via Get-Volume (newer API)
    $v2 = Get-Volume -FileSystemLabel $Config.UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($v2 -and $v2.DriveLetter) { return ($v2.DriveLetter + ':') }
    throw "USB drive labelled '$($Config.UsbLabel)' not found. Plug it in and check its label in Explorer."
  }
  return $vol.DriveLetter  # e.g. "E:"
}

function Assert-Tools {
  foreach ($t in @('ssh','scp','tar')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
      throw "Required tool '$t' not found. Install OpenSSH Client: Settings > Apps > Optional features > Add > OpenSSH Client. 'tar' ships with Windows 10/11."
    }
  }
  if (-not (Test-Path $Config.SshKey)) {
    throw "SSH key not found at $($Config.SshKey). Create with: ssh-keygen -t ed25519  and copy the .pub to the VPS authorized_keys."
  }
}

function Invoke-Remote([string]$bashScript) {
  # One ssh call, feeds bash script via stdin. Returns stdout.
  $sshArgs = @('-o','StrictHostKeyChecking=accept-new','-o',"ConnectTimeout=$($Config.SshTimeoutSec)",
               '-p',$Config.RemotePort,'-i',$Config.SshKey,
               "$($Config.RemoteUser)@$($Config.RemoteHost)",'bash -s')
  $out = $bashScript | ssh @sshArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Remote step failed:`n$out" }
  return $out
}

function Install-BackupSchedule {
  $scriptPath = $MyInvocation.MyCommand.Path
  if (-not $scriptPath) { $scriptPath = $PSCommandPath }
  foreach ($t in $Config.ScheduleTimes) {
    $name = "ERPNext USB Backup $($t.Replace(':','h'))"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]$t)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -WakeToRun
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Log "Scheduled task created: $name @ $t daily" 'Green'
  }
  Write-Log 'Done. Backups will run 3x daily when the laptop is on.' 'Green'
}

function Uninstall-BackupSchedule {
  foreach ($t in $Config.ScheduleTimes) {
    $name = "ERPNext USB Backup $($t.Replace(':','h'))"
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Removed: $name" 'Yellow'
  }
}

# ---------------- main ----------------
if ($UninstallSchedule) { Uninstall-BackupSchedule; exit 0 }
if ($InstallSchedule)  { Install-BackupSchedule; exit 0 }

Assert-Tools
$drive = Get-BackupDrive
$backupDir = Join-Path $drive $Config.BackupSubDir
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$logFile = Join-Path $backupDir 'usb_backup.log'
Start-Transcript -Path $logFile -Append | Out-Null
try {
  Write-Log "USB drive: $drive  ->  $backupDir" 'Cyan'
  $freeGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB, 1)
  Write-Log "Free space on USB: ${freeGB} GB" 'Cyan'

  # ---- STEP 1: build ONE tar.gz on the VPS (db + files + apps + compose) ----
  Write-Log 'STEP 1/4 — creating snapshot on VPS...' 'Cyan'
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HH-mm-ss')
  # NOTE: $ signs escaped for PowerShell here-string; remote sees real bash vars.
  $remote = @'
set -euo pipefail
WORKDIR="__WORKDIR__"; STAMP="__STAMP__"
DB_C="__DBC__"; BE_C="__BEC__"; SITE="__SITE__"
STAGE="/tmp/erpnext_usb_$STAMP"; OUT="/tmp/erpnext_complete_backup_$STAMP.tar.gz"
SITES="/home/frappe/frappe-bench/sites"
rm -rf "$STAGE"; mkdir -p "$STAGE/apps" "$STAGE/docker_config"
echo "[1/4] db dump..."
SITE_DB=$(docker exec "$BE_C" cat "$SITES/$SITE/site_config.json" | grep -o '"db_name": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
[ -z "$SITE_DB" ] && { echo "ERROR: cannot read db_name"; exit 1; }
DBPASS=$(docker exec "$BE_C" cat "$SITES/$SITE/site_config.json" | grep -o '"db_password": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
docker exec "$DB_C" sh -c "mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --routines --triggers '$SITE_DB'" > "$STAGE/database.sql" 2>"$STAGE/dump.err" || { cat "$STAGE/dump.err"; exit 1; }
[ ! -s "$STAGE/database.sql" ] && { echo "ERROR: empty dump"; exit 1; }
rm -f "$STAGE/dump.err"
echo "[2/4] configs..."
docker cp "$BE_C:$SITES/common_site_config.json" "$STAGE/common_site_config.json"
docker cp "$BE_C:$SITES/$SITE/site_config.json" "$STAGE/site_config.json"
docker exec "$BE_C" cat "$SITES/apps.txt" > "$STAGE/apps.txt"
cp "$WORKDIR/docker-compose.yml" "$STAGE/docker_config/" 2>/dev/null || true
[ -d "$WORKDIR/config" ] && cp -r "$WORKDIR/config" "$STAGE/docker_config/" || true
echo "$SITE_DB" > "$STAGE/db_name.txt"
echo "[3/4] site files..."
docker cp "$BE_C:$SITES/$SITE/private" "$STAGE/private" 2>/dev/null || true
docker cp "$BE_C:$SITES/$SITE/public" "$STAGE/public" 2>/dev/null || true
echo "[4/4] custom apps..."
APPS=$(docker exec "$BE_C" cat "$SITES/apps.txt" 2>/dev/null | grep -vE '^(frappe|erpnext)$' | grep -v '^$' || true)
for APP in $APPS; do
  echo "  + $APP"
  docker cp "$BE_C:/home/frappe/frappe-bench/apps/$APP" "$STAGE/apps/$APP" || { echo "ERROR copying $APP"; exit 1; }
done
tar -czf "$OUT" -C "$STAGE" .
sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"
echo "READY OUT=$OUT SHA=$(cat $OUT.sha256) SIZE=$(du -h $OUT | cut -f1)"
'@
  $remote = $remote.Replace('__WORKDIR__', $Config.RemoteWorkDir).Replace('__STAMP__', $stamp).Replace('__DBC__', $Config.DbContainer).Replace('__BEC__', $Config.BackendContainer).Replace('__SITE__', $Config.SiteName)

  $result = Invoke-Remote $remote
  Write-Host $result
  $line = ($result | Select-String 'READY OUT=(\S+) SHA=(\S+)').Matches
  if (-not $line) { throw "Could not parse remote READY line.`n$result" }
  $remoteFile = $line.Groups[1].Value
  $remoteSha = $line.Groups[2].Value.ToLower()
  $base = [IO.Path]::GetFileName($remoteFile)
  Write-Log "Remote snapshot: $base  sha=$remoteSha" 'Green'

  # ---- STEP 2: download to .part first (never leave a half file as final) ----
  Write-Log 'STEP 2/4 — downloading to USB (.part)...' 'Cyan'
  $part  = Join-Path $backupDir ($base + '.part')
  $final = Join-Path $backupDir $base
  $shaFile = "$final.sha256"
  if (Test-Path $part) { Remove-Item $part -Force }
  $scpTarget = "$($Config.RemoteUser)@$($Config.RemoteHost):$remoteFile"
  & scp -o StrictHostKeyChecking=accept-new -P $Config.RemotePort -i $Config.SshKey $scpTarget $part
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $part)) { throw 'scp download failed' }

  # ---- STEP 3: verify — sha256 + tar listing test (restorable, not corrupt) ---
  Write-Log 'STEP 3/4 — verifying checksum + archive integrity...' 'Cyan'
  $localSha = (Get-FileHash $part -Algorithm SHA256).Hash.ToLower()
  if ($localSha -ne $remoteSha) {
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    throw "CHECKSUM MISMATCH (remote=$remoteSha local=$localSha). Part deleted, keeps old good backups."
  }
  Write-Log 'Checksum OK' 'Green'
  # tar -tzf equivalent on Windows (bsdtar ships with Win10+). Fails loudly if corrupt.
  & tar -tzf $part | Out-Null
  if ($LASTEXITCODE -ne 0) { Remove-Item $part -Force -ErrorAction SilentlyContinue; throw 'Archive listing test failed — file corrupt, deleted.' }
  # required members present?
  $members = & tar -tzf $part
  foreach ($need in @('database.sql','site_config.json','apps.txt')) {
    if (-not ($members -match $need)) { throw "Archive missing required member: $need" }
  }
  # gzip integrity: expand first 1MB? tar test above already covers it.
  Move-Item $part $final -Force
  Set-Content -Path $shaFile -Value "$localSha  $base" -NoNewline
  Set-Content -Path "$final.verified.txt" -Value "verified $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  sha=$localSha  size=$((Get-Item $final).Length)"
  Write-Log "Verified + saved: $base ($([math]::Round((Get-Item $final).Length/1MB,1)) MB)" 'Green'

  # cleanup VPS temp files (best effort)
  Invoke-Remote "rm -f '$remoteFile' '$remoteFile.sha256'; rm -rf '/tmp/erpnext_usb_$stamp'" | Out-Null

  # ---- STEP 4: retention — keep ONLY latest 3, permanent delete incl. trash ---
  Write-Log "STEP 4/4 — retention: keeping latest $($Config.KeepBackups)..." 'Cyan'
  $all = Get-ChildItem $backupDir -Filter 'erpnext_complete_backup_*.tar.gz' | Sort-Object Name -Descending
  if ($all.Count -gt $Config.KeepBackups) {
    $old = $all | Select-Object -Skip $Config.KeepBackups
    foreach ($f in $old) {
      Write-Log "Deleting old: $($f.Name)" 'Yellow'
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
      Remove-Item ($f.FullName + '.sha256') -Force -ErrorAction SilentlyContinue
      Remove-Item ($f.FullName + '.verified.txt') -Force -ErrorAction SilentlyContinue
    }
    # Permanent delete: empty this drive's Recycle Bin so space is really freed
    # and stale copies can't be restored by accident.
    $letter = $drive.TrimEnd(':')
    try { Clear-RecycleBin -DriveLetter $letter -Force -ErrorAction Stop; Write-Log "Recycle Bin ($letter`:) emptied (permanent)." 'Yellow' }
    catch { Write-Log 'Clear-RecycleBin skipped (admin needed?) — trying $RECYCLE.BIN wipe...' 'Yellow' }
    $recycle = Join-Path $drive '$RECYCLE.BIN'
    if (Test-Path $recycle) { Get-ChildItem $recycle -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $kept = Get-ChildItem $backupDir -Filter 'erpnext_complete_backup_*.tar.gz' | Sort-Object Name -Descending
  Write-Log "Kept ($($kept.Count)):" 'Green'
  $kept | ForEach-Object { Write-Log "  - $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)" 'Green' }

  Write-Log 'BACKUP COMPLETED OK' 'Green'
}
catch {
  Write-Log "FAILED: $($_.Exception.Message)" 'Red'
  exit 1
}
finally { Stop-Transcript | Out-Null }
