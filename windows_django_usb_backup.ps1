<#
.SYNOPSIS
  Self-contained DJANGO USB backup for a Windows laptop. Backup-only.
  Builds ONE verified django_complete_backup_*.tar.gz on the VPS straight
  onto the external USB drive labelled BACKUP, keeps only the latest 3,
  permanently deletes the rest (including trash).

  Same archive layout as django_back_restore.sh so your existing
  restore/verify flow can still read it:
    <root>/ database.sql.gz, project.tar.gz, media.tar.gz,
            manifest.txt, checksums.sha256

.USAGE
  1. Plug in the USB drive labelled BACKUP (any letter, found by label).
  2. Edit the CONFIG block below once (VPS ip/user/key, project paths).
  3. Right-click > "Run with PowerShell" — or:
       powershell -ExecutionPolicy Bypass -File .\windows_django_usb_backup.ps1
     First run:  .\windows_django_usb_backup.ps1 -InstallSchedule
     Manual run: .\windows_django_usb_backup.ps1
     Remove:     .\windows_django_usb_backup.ps1 -UninstallSchedule

.REQUIREMENTS
  - Windows 10/11 with OpenSSH Client (ssh + scp). Script checks for them.
  - SSH KEY auth (no sshpass on Windows). ssh-keygen once, append .pub
    to the VPS ~/.ssh/authorized_keys.
  - USB volume label exactly: BACKUP
#>
param(
  [switch]$InstallSchedule,
  [switch]$UninstallSchedule
)

$ErrorActionPreference = 'Stop'

# ============================ CONFIG — EDIT ME ============================
$Config = @{
  RemoteUser       = 'autopro'
  RemoteHost       = '185.27.135.97'
  RemotePort       = '2394'
  SshKey           = "$env:USERPROFILE\.ssh\id_ed25519"
  RemoteProjectDir = '/home/autopro/erp_demo'
  RemoteBackupDir  = '/home/autopro/django_backups'
  ProdComposeFile  = 'docker-compose.prod.yml'
  ProdEnvFile      = '.env.prod'

  UsbLabel      = 'BACKUP'
  BackupSubDir  = 'django_backups'    # <USB>:\django_backups\
  FilePrefix    = 'django_complete_backup_'
  KeepBackups   = 3
  ScheduleTimes = @('08:00','13:00','18:00')  # 3x daily
  SshTimeoutSec = 20
}
# ========================== END CONFIG =====================================

function Write-Log($msg, $color='White') {
  $ts = Get-Date -Format 'HH:mm:ss'
  Write-Host "[$ts] $msg" -ForegroundColor $color
}

function Get-BackupDrive {
  $vol = Get-CimInstance Win32_Volume -Filter "Label = '$($Config.UsbLabel)'" -ErrorAction SilentlyContinue |
         Where-Object { $_.DriveLetter } | Select-Object -First 1
  if (-not $vol) {
    $v2 = Get-Volume -FileSystemLabel $Config.UsbLabel -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($v2 -and $v2.DriveLetter) { return ($v2.DriveLetter + ':') }
    throw "USB drive labelled '$($Config.UsbLabel)' not found. Plug it in and check its label in Explorer."
  }
  return $vol.DriveLetter
}

function Assert-Tools {
  foreach ($t in @('ssh','scp','tar')) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
      throw "Required tool '$t' not found. Install OpenSSH Client: Settings > Apps > Optional features > Add > OpenSSH Client. 'tar' ships with Windows 10/11."
    }
  }
  if (-not (Test-Path $Config.SshKey)) {
    throw "SSH key not found at $($Config.SshKey). Create with: ssh-keygen -t ed25519 and copy the .pub to the VPS authorized_keys."
  }
}

function Invoke-Remote([string]$bashScript) {
  $sshArgs = @('-o','StrictHostKeyChecking=accept-new','-o',"ConnectTimeout=$($Config.SshTimeoutSec)",
               '-p',$Config.RemotePort,'-i',$Config.SshKey,
               "$($Config.RemoteUser)@$($Config.RemoteHost)",'bash -s')
  $out = $bashScript | ssh @sshArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Remote step failed:`n$out" }
  return $out
}

function Install-BackupSchedule {
  $scriptPath = $PSCommandPath
  if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
  foreach ($t in $Config.ScheduleTimes) {
    $name = "Django USB Backup $($t.Replace(':','h'))"
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
    $name = "Django USB Backup $($t.Replace(':','h'))"
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
$logFile = Join-Path $backupDir 'django_usb_backup.log'
Start-Transcript -Path $logFile -Append | Out-Null
try {
  Write-Log "USB drive: $drive  ->  $backupDir" 'Cyan'
  $freeGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB, 1)
  Write-Log "Free space on USB: ${freeGB} GB" 'Cyan'

  # ---- STEP 1: build ONE django tar.gz on the VPS (mirrors django_back_restore.sh) ----
  Write-Log 'STEP 1/4 — creating Django snapshot on VPS...' 'Cyan'
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HH-mm-ss')
  $remote = @'
set -Eeuo pipefail
project_dir="__PROJECTDIR__"; backup_dir="__BACKUPDIR__"
compose_file="__COMPOSE__"; env_file="__ENVFILE__"; stamp="__STAMP__"
backup_name="django_complete_backup_$stamp"; backup_file="$backup_name.tar.gz"
temp="$backup_dir/$backup_name"; archive="$backup_dir/$backup_file"
cd "$project_dir"
mkdir -p "$backup_dir"
rm -rf "$temp"; mkdir -p "$temp"
docker compose --env-file "$env_file" -f "$compose_file" config >/dev/null
docker compose --env-file "$env_file" -f "$compose_file" exec -T db sh -lc \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick --routines --triggers --events --no-tablespaces "$MYSQL_DATABASE"' \
  </dev/null | gzip -1 > "$temp/database.sql.gz"
gzip -t "$temp/database.sql.gz"
tar -czf "$temp/project.tar.gz" \
  --warning=no-file-changed \
  --exclude='./.git' --exclude='./venv' --exclude='./.venv' \
  --exclude='./__pycache__' --exclude='*/__pycache__' --exclude='*.pyc' \
  --exclude='./media' --exclude='./logs' --exclude='./runtime' \
  --exclude='./backups' --exclude='./staticfiles' --exclude='*.log' \
  --exclude='./back_restore.env' --exclude='./.env' --exclude='./.env.prod' \
  -C "$project_dir" . || {
  s=$?; if [ "$s" -gt 1 ]; then echo "project tar failed: $s" >&2; exit "$s"; fi
}
if [ -d "$project_dir/media" ]; then
  tar -czf "$temp/media.tar.gz" -C "$project_dir" media
else
  tar -czf "$temp/media.tar.gz" --files-from /dev/null
fi
db_name="$(docker compose --env-file "$env_file" -f "$compose_file" exec -T db sh -lc 'printf %s "$MYSQL_DATABASE"' </dev/null)"
table_count="$(docker compose --env-file "$env_file" -f "$compose_file" exec -T db sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N "$MYSQL_DATABASE" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()"' </dev/null 2>/dev/null)"
git_commit="$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
cat > "$temp/manifest.txt" <<EOF
created_at=$(date --iso-8601=seconds)
source_host=$(hostname)
source_project=$project_dir
database=$db_name
table_count=$table_count
git_commit=$git_commit
EOF
(cd "$temp" && sha256sum database.sql.gz project.tar.gz media.tar.gz manifest.txt > checksums.sha256)
rm -f "$archive"
tar -czf "$archive" -C "$backup_dir" "$backup_name"
rm -rf "$temp"
[ -s "$archive" ]
sha=$(sha256sum "$archive" | awk '{print $1}')
echo "READY OUT=$archive SHA=$sha SIZE=$(du -h $archive | cut -f1)"
'@
  $remote = $remote.Replace('__PROJECTDIR__', $Config.RemoteProjectDir).Replace('__BACKUPDIR__', $Config.RemoteBackupDir).Replace('__COMPOSE__', $Config.ProdComposeFile).Replace('__ENVFILE__', $Config.ProdEnvFile).Replace('__STAMP__', $stamp)

  $result = Invoke-Remote $remote
  Write-Host $result
  $line = ($result | Select-String 'READY OUT=(\S+) SHA=(\S+)').Matches
  if (-not $line) { throw "Could not parse remote READY line.`n$result" }
  $remoteFile = $line.Groups[1].Value
  $remoteSha = $line.Groups[2].Value.ToLower()
  $base = [IO.Path]::GetFileName($remoteFile)
  Write-Log "Remote snapshot: $base  sha=$remoteSha" 'Green'

  # ---- STEP 2: download to .part first ----
  Write-Log 'STEP 2/4 — downloading to USB (.part)...' 'Cyan'
  $part  = Join-Path $backupDir ($base + '.part')
  $final = Join-Path $backupDir $base
  if (Test-Path $part) { Remove-Item $part -Force }
  $scpTarget = "$($Config.RemoteUser)@$($Config.RemoteHost):$remoteFile"
  & scp -o StrictHostKeyChecking=accept-new -P $Config.RemotePort -i $Config.SshKey $scpTarget $part
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $part)) { throw 'scp download failed' }

  # ---- STEP 3: verify — sha256 + outer listing + required members ----
  Write-Log 'STEP 3/4 — verifying checksum + archive integrity...' 'Cyan'
  $localSha = (Get-FileHash $part -Algorithm SHA256).Hash.ToLower()
  if ($localSha -ne $remoteSha) {
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    throw "CHECKSUM MISMATCH (remote=$remoteSha local=$localSha). Part deleted, old good backups kept."
  }
  Write-Log 'Checksum OK' 'Green'
  & tar -tzf $part | Out-Null
  if ($LASTEXITCODE -ne 0) { Remove-Item $part -Force -ErrorAction SilentlyContinue; throw 'Archive listing test failed — corrupt, deleted.' }
  $members = & tar -tzf $part
  foreach ($need in @('database.sql.gz','project.tar.gz','media.tar.gz','manifest.txt','checksums.sha256')) {
    if (-not ($members -match $need)) { throw "Archive missing required member: $need" }
  }
  Write-Log 'Archive members OK (db + project + media + manifest + checksums)' 'Green'
  Move-Item $part $final -Force
  Set-Content -Path ($final + '.sha256') -Value "$localSha  $base" -NoNewline
  Set-Content -Path ($final + '.verified.txt') -Value "verified $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  sha=$localSha  size=$((Get-Item $final).Length)"
  Write-Log "Verified + saved: $base ($([math]::Round((Get-Item $final).Length/1MB,1)) MB)" 'Green'

  Invoke-Remote "rm -f '$remoteFile'" | Out-Null

  # ---- STEP 4: retention — keep ONLY latest 3, permanent delete ----
  Write-Log "STEP 4/4 — retention: keeping latest $($Config.KeepBackups)..." 'Cyan'
  $filter = $Config.FilePrefix + '*.tar.gz'
  $all = Get-ChildItem $backupDir -Filter $filter | Sort-Object Name -Descending
  if ($all.Count -gt $Config.KeepBackups) {
    $old = $all | Select-Object -Skip $Config.KeepBackups
    foreach ($f in $old) {
      Write-Log "Deleting old: $($f.Name)" 'Yellow'
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
      Remove-Item ($f.FullName + '.sha256') -Force -ErrorAction SilentlyContinue
      Remove-Item ($f.FullName + '.verified.txt') -Force -ErrorAction SilentlyContinue
    }
    $letter = $drive.TrimEnd(':')
    try { Clear-RecycleBin -DriveLetter $letter -Force -ErrorAction Stop; Write-Log "Recycle Bin ($letter`:) emptied (permanent)." 'Yellow' }
    catch { Write-Log 'Clear-RecycleBin skipped (admin needed?) — trying $RECYCLE.BIN wipe...' 'Yellow' }
    $recycle = Join-Path $drive '$RECYCLE.BIN'
    if (Test-Path $recycle) { Get-ChildItem $recycle -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $kept = Get-ChildItem $backupDir -Filter $filter | Sort-Object Name -Descending
  Write-Log "Kept ($($kept.Count)):" 'Green'
  $kept | ForEach-Object { Write-Log "  - $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)" 'Green' }

  Write-Log 'BACKUP COMPLETED OK' 'Green'
}
catch {
  Write-Log "FAILED: $($_.Exception.Message)" 'Red'
  exit 1
}
finally { Stop-Transcript | Out-Null }
