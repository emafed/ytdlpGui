# ytdlpGui - Micro Server HTTP in PowerShell
$ErrorActionPreference = "Continue"

$port = 8888
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$webDir = Join-Path $scriptDir "web"
$downloadsDir = Join-Path $scriptDir "downloads"
$logDir = Join-Path $scriptDir "log"
$historyFile = Join-Path $logDir "downloads.txt"
$ytdlpExe = Join-Path $scriptDir "yt-dlp.exe"

# Forza UTF-8 per l'output di yt-dlp (Python) cosi i nomi accentati restano corretti
# anche quando l'output viene rediretto su file.
$env:PYTHONIOENCODING = "utf-8"

function Find-Executable([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---- Rilevamento automatico ffmpeg / ffprobe ----
$ffmpegExe = $null
$ffprobeExe = $null
$ffmpegCandidates = New-Object System.Collections.Generic.List[string]
$ffmpegCandidates.Add((Join-Path $scriptDir "_internal\ffmpeg.exe"))
$ffmpegCandidates.Add((Join-Path $scriptDir "ffmpeg.exe"))
$localAppData = [Environment]::GetFolderPath("LocalApplicationData")
$winGetDir = Join-Path $localAppData "Microsoft\WinGet\Packages"
if (Test-Path -LiteralPath $winGetDir) {
    Get-ChildItem -LiteralPath $winGetDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*ffmpeg*" } | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "ffmpeg-*" -ErrorAction SilentlyContinue | ForEach-Object {
                $ffmpegCandidates.Add((Join-Path $_.FullName "bin\ffmpeg.exe"))
            }
        }
}
$pathFfmpeg = Find-Executable "ffmpeg.exe"
if ($pathFfmpeg) { $ffmpegCandidates.Add($pathFfmpeg) }
foreach ($candidate in $ffmpegCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $ffmpegExe = $candidate
        $siblingProbe = Join-Path ([System.IO.Path]::GetDirectoryName($candidate)) "ffprobe.exe"
        if (Test-Path -LiteralPath $siblingProbe) { $ffprobeExe = $siblingProbe }
        else {
            $pathProbe = Find-Executable "ffprobe.exe"
            if ($pathProbe) { $ffprobeExe = $pathProbe }
        }
        break
    }
}
if ($ffmpegExe) { Write-Host "FFmpeg trovato: $ffmpegExe" -ForegroundColor Green }
else { Write-Host "FFmpeg non trovato - gli audio verranno scaricati nel formato originale" -ForegroundColor Yellow }

if (!(Test-Path -LiteralPath $downloadsDir)) {
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
}

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# ---- Configurazione (config.json) ----
# Campi supportati:
#   transferDirectory: cartella in cui spostare i file al termine del download
#                      quando la casella "Trasferisci al termine" e' selezionata.
$configFile = Join-Path $scriptDir "config.json"
$transferDir = ""
if (!(Test-Path -LiteralPath $configFile)) {
    $defaultConfig = @{ transferDirectory = "" } | ConvertTo-Json
    [System.IO.File]::WriteAllText($configFile, $defaultConfig, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Creato file di configurazione: $configFile" -ForegroundColor Gray
}
try {
    # Lettura tollerante: accetta sia i backslash singoli di Windows
    # (C:\Video) sia quelli escapati di JSON (C:\\Video).
    $rawConfig = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
    $matchConfig = [regex]::Match($rawConfig, '"transferDirectory"\s*:\s*"(.*?)"')
    if ($matchConfig.Success) {
        $transferDir = $matchConfig.Groups[1].Value -replace '\\\\', '\' -replace '\\"', '"'
        $transferDir = [Environment]::ExpandEnvironmentVariables($transferDir.Trim())
    }
} catch {
    Write-Host "[CONFIG] Impossibile leggere config.json: $_" -ForegroundColor Yellow
}
if ($transferDir) {
    Write-Host "Cartella di trasferimento: $transferDir" -ForegroundColor Green
} else {
    Write-Host "Cartella di trasferimento non configurata (config.json -> transferDirectory)" -ForegroundColor Yellow
}

# Nota: i log dei task falliti restano in log/ finche' non vengono eliminati
# manualmente; i task completati con successo non lasciano file di log.

# Storage dei task di download in background (il server e' single-thread,
# quindi una semplice hashtable e' sufficiente).
$tasks = @{}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "Impossibile avviare il server sulla porta $port. Errore: $_" -ForegroundColor Yellow
    throw $_
}

Start-Process $prefix

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "   ytdlpGui - Server Locale Attivo!                    " -ForegroundColor Green
Write-Host "   URL Interfaccia: $prefix                           " -ForegroundColor White
Write-Host "   Premi CTRL+C per arrestare il server                " -ForegroundColor Gray
Write-Host "=======================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Funzioni di supporto
# ---------------------------------------------------------------------------

function Send-Response($context, $statusCode, $contentType, $contentBytes) {
    try {
        $response = $context.Response
        $response.StatusCode = $statusCode
        $response.ContentType = $contentType
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
        $response.ContentLength64 = $contentBytes.Length
        if ($contentBytes.Length -gt 0) {
            $response.OutputStream.Write($contentBytes, 0, $contentBytes.Length)
        }
        $response.OutputStream.Close()
    } catch {
        # Client disconnesso: ignora
    }
}

function Send-Json($context, $statusCode, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Response $context $statusCode "application/json; charset=utf-8" $bytes
}

function Send-ErrorJson($context, $statusCode, $message) {
    Send-Json $context $statusCode @{ error = $message }
}

# Converte un singolo argomento nella forma quotata accettata da CreateProcess.
function ConvertTo-CmdArg([string]$value) {
    if ($null -eq $value) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-CmdLine([string[]]$arguments) {
    return ($arguments | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
}

# Esegue un processo esterno e ne cattura stdout, stderr ed exit code.
# La lettura asincrona dei due stream evita il deadlock che si verifica
# leggendo stdout e stderr in sequenza quando il buffer di uno dei due si riempie.
function Invoke-ProcessCapture([string]$fileName, [string[]]$arguments) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $fileName
        $psi.Arguments = ConvertTo-CmdLine $arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        return [pscustomobject]@{
            stdout   = $stdoutTask.Result
            stderr   = $stderrTask.Result
            exitCode = $proc.ExitCode
        }
    } catch {
        return $null
    }
}

function Read-SharedFileLines($filePath) {
    $result = New-Object System.Collections.Generic.List[string]
    # Nota: si usa la virgola in uscita per evitare che PowerShell "srotoli"
    # gli array con un solo elemento trasformandoli in una stringa.
    if (!(Test-Path -LiteralPath $filePath)) { return , @() }
    try {
        $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            while (!$sr.EndOfStream) {
                $line = $sr.ReadLine()
                if ($line) {
                    # Rimuove eventuali codici ANSI
                    $line = $line -replace '\x1b\[[0-9;]*m', ''
                    if ($line) { $result.Add($line) }
                }
            }
            $sr.Close()
        } finally {
            $fs.Close()
        }
    } catch {}
    return , $result.ToArray()
}

function Read-FileTail([string]$filePath, [int]$maxBytes) {
    if (!(Test-Path -LiteralPath $filePath)) { return "" }
    try {
        $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = [Math]::Min([long]$maxBytes, $fs.Length)
            if ($len -le 0) { return "" }
            $fs.Seek($fs.Length - $len, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] $len
            $fs.Read($buf, 0, [int]$len) | Out-Null
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally {
            $fs.Close()
        }
    } catch {
        return ""
    }
}

function Get-MediaDuration([string]$filePath) {
    if (-not $ffprobeExe -or -not (Test-Path -LiteralPath $filePath)) { return 0.0 }
    $result = Invoke-ProcessCapture $ffprobeExe @("-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", $filePath)
    if ($result) {
        $output = $result.stdout.Trim()
        if ($output -match '^[\d\.]+$') { return [double]$output }
    }
    return 0.0
}

# Decodifica completa del file con ffmpeg: se non ci sono errori il file e'
# integro. Serve a intercettare download troncati/corrotti prima di consegnarli.
function Test-MediaIntegrity([string]$filePath) {
    if (-not $ffmpegExe -or [string]::IsNullOrWhiteSpace($filePath)) { return $false }
    if (-not (Test-Path -LiteralPath $filePath)) { return $false }
    $result = Invoke-ProcessCapture $ffmpegExe @("-hide_banner", "-v", "error", "-xerror", "-nostdin", "-i", $filePath, "-f", "null", "-")
    if (-not $result -or $result.exitCode -ne 0) { return $false }
    return [string]::IsNullOrWhiteSpace($result.stderr)
}

# Titolo leggibile per i metadati: rimuove i caratteri speciali (che i Garmin
# mostrano male) senza usare underscore, lasciando lettere, numeri e spazi.
function ConvertTo-CleanTitle([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $name }
    $clean = $name -replace '[^\p{L}\p{N} ]', ' '
    $clean = ($clean -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return $name }
    return $clean
}

# Argomenti ffmpeg per rendere i file compatibili con i Garmin: niente metadati
# ereditati dal contenitore sorgente, titolo pulito, tag ID3v2.3+v1, 44.1 kHz
# stereo e CBR.
function Get-GarminCompatArgs([string]$format, [string]$title) {
    $compat = @('-map_metadata', '-1')
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $compat += @('-metadata', "title=$title")
    }
    switch ($format) {
        'mp3' { $compat += @('-ar', '44100', '-ac', '2', '-id3v2_version', '3', '-write_id3v1', '1', '-write_xing', '1') }
        'm4a' { $compat += @('-ar', '44100', '-ac', '2', '-movflags', '+faststart') }
        'aac' { $compat += @('-ar', '44100', '-ac', '2') }
    }
    return $compat
}

# Rileva nei log di yt-dlp i segnali di download non integro che non sempre
# diventano un "ERROR:" fatale (fragment saltati, retry esauriti, ...).
function Test-DownloadLogProblem($lines) {
    foreach ($l in $lines) {
        if ($l -match '^\s*ERROR:') { return $true }
        if ($l -match 'fragment not found|Skipping fragment|Giving up after') { return $true }
    }
    return $false
}

# Restituisce l'array di argomenti codec per ffmpeg.
function Get-AudioCodecArgs([string]$format, [string]$quality) {
    $isVbr = ($quality -eq '0')
    $kbps = 128
    if (-not $isVbr) {
        $digits = ($quality -replace '[^0-9]', '')
        if ($digits) { $kbps = [int]$digits }
    }
    switch ($format) {
        'mp3'  { if ($isVbr) { return @('-c:a', 'libmp3lame', '-q:a', '0') } else { return @('-c:a', 'libmp3lame', '-b:a', "${kbps}k") } }
        'm4a'  { if ($isVbr) { return @('-c:a', 'aac', '-q:a', '2') } else { return @('-c:a', 'aac', '-b:a', "${kbps}k") } }
        'aac'  { if ($isVbr) { return @('-c:a', 'aac', '-q:a', '2') } else { return @('-c:a', 'aac', '-b:a', "${kbps}k") } }
        'opus' { if ($isVbr) { return @('-c:a', 'libopus', '-b:a', '128k') } else { return @('-c:a', 'libopus', '-b:a', "${kbps}k") } }
        'wav'  { return @('-c:a', 'pcm_s16le') }
        'flac' { return @('-c:a', 'flac') }
        default { return @('-c:a', 'libmp3lame', '-b:a', "${kbps}k") }
    }
}

# Prova a risolvere un percorso di file citato nei log di yt-dlp.
# yt-dlp puo stampare percorsi assoluti, relativi o relativi alla cartella -P.
function Resolve-ExistingFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $path = $path.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ([System.IO.Path]::IsPathRooted($path)) {
        $candidates.Add($path)
    } else {
        $candidates.Add((Join-Path $downloadsDir $path))
        $candidates.Add((Join-Path $scriptDir $path))
        if ($path -match '^downloads[\\/](.+)$') {
            $candidates.Add((Join-Path $downloadsDir $matches[1]))
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
        } catch { continue }
        if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
    }
    return $null
}

function Resolve-DownloadedPath($lines, $startTime, $pathFile) {
    # 1. Fonte primaria: percorso scritto direttamente da yt-dlp (--print-to-file).
    if ($pathFile -and (Test-Path -LiteralPath $pathFile)) {
        $printed = Read-SharedFileLines $pathFile
        for ($i = $printed.Count - 1; $i -ge 0; $i--) {
            $resolved = Resolve-ExistingFile $printed[$i]
            if ($resolved) { return $resolved }
        }
    }

    # 2. Parsing dei log di yt-dlp.
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '\[Merger\]\s+Merging formats into\s+"(.+)"') {
            $candidates.Add($matches[1])
        } elseif ($line -match '\[download\]\s+Destination:\s+(.+)') {
            $candidates.Add($matches[1])
        } elseif ($line -match '\[download\]\s+(.+?)\s+has already been downloaded') {
            $candidates.Add($matches[1])
        }
    }
    for ($i = $candidates.Count - 1; $i -ge 0; $i--) {
        $resolved = Resolve-ExistingFile $candidates[$i]
        if ($resolved) { return $resolved }
    }

    # 3. Fallback: il file piu' recente nella cartella download creato dopo l'avvio
    #    del task (copre encoding del nome file o messaggi diversi tra versioni).
    if ($startTime) {
        $recent = Get-ChildItem -LiteralPath $downloadsDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -ge $startTime -and
                $_.Name -notmatch '\.(part|ytdl|temp|tmp)(-|$)' -and
                $_.Name -notlike '*.__converting__.*'
            } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($recent) {
            Write-Host "[CONVERT] Path dai log non risolto, uso il file piu' recente: $($recent.Name)" -ForegroundColor Yellow
            return $recent.FullName
        }
    }

    if ($candidates.Count -gt 0) {
        Write-Host "[CONVERT] Candidati non trovati su disco: $($candidates -join ' | ')" -ForegroundColor Red
    }
    return $null
}

# Rinomina un singolo file applicando la sanitizzazione del nome (senza sovrascrivere).
function Rename-SanitizedFile([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    $dir = [System.IO.Path]::GetDirectoryName($path)
    $name = [System.IO.Path]::GetFileName($path)
    $ext = [System.IO.Path]::GetExtension($name)
    $base = $name.Substring(0, $name.Length - $ext.Length)
    $sanitized = (($base -replace '[^\w\-]', '_') -replace '_+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($sanitized) -or $sanitized -eq $base) { return $path }

    $newName = "$sanitized$ext"
    $newPath = Join-Path $dir $newName
    if (Test-Path -LiteralPath $newPath) {
        $i = 1
        while (Test-Path -LiteralPath (Join-Path $dir "$sanitized`_$i$ext")) { $i++ }
        $newName = "$sanitized`_$i$ext"
        $newPath = Join-Path $dir $newName
    }
    try {
        Rename-Item -LiteralPath $path -NewName $newName
        Write-Host "[RENAME] $name -> $newName" -ForegroundColor Magenta
        return $newPath
    } catch {
        return $path
    }
}

# Copia un file su un dispositivo portatile (MTP, es. Garmin collegato via
# USB) navigando lo spazio dei nomi di Esplora File. Restituisce il percorso
# di destinazione se la copia va a buon fine, altrimenti $null.
function Copy-FileToPortableDevice([string]$filePath, [string]$devicePath) {
    $parts = @($devicePath -split '[\\/]' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return $null }
    if ($parts[0] -match '^(Questo PC|This PC|PC|Computer)$') {
        $parts = @($parts | Select-Object -Skip 1)
    }
    if ($parts.Count -eq 0) { return $null }

    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace(17) # ssfDRIVES = "Questo PC"
        foreach ($part in $parts) {
            if (-not $folder) { break }
            # Sui dispositivi MTP i parsing name non coincidono con i nomi
            # mostrati: conviene cercare per nome tra gli elementi della cartella.
            $item = $null
            foreach ($candidate in @($folder.Items())) {
                if ($candidate.Name -ieq $part) { $item = $candidate; break }
            }
            if (-not $item) {
                Write-Host "[TRANSFER] Elemento non trovato sul dispositivo: $part" -ForegroundColor Red
                return $null
            }
            if (-not $item.IsFolder) {
                Write-Host "[TRANSFER] Elemento non e' una cartella: $part" -ForegroundColor Red
                return $null
            }
            $folder = $item.GetFolder
        }
        if (-not $folder) { return $null }

        $fileName = [System.IO.Path]::GetFileName($filePath)
        $exists = $false
        foreach ($candidate in @($folder.Items())) {
            if ($candidate.Name -ieq $fileName) { $exists = $true; break }
        }
        if ($exists) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
            $ext = [System.IO.Path]::GetExtension($filePath)
            $i = 1
            while ($true) {
                $candidateName = "$base`_$i$ext"
                $found = $false
                foreach ($candidate in @($folder.Items())) {
                    if ($candidate.Name -ieq $candidateName) { $found = $true; break }
                }
                if (-not $found) { $fileName = $candidateName; break }
                $i++
            }
        }

        # 4 (nessuna finestra di avanzamento) + 16 (Si a tutto) + 512 + 1024 (nessun popup)
        $folder.CopyHere($filePath, 1556)
        Write-Host "[TRANSFER] Copia su dispositivo avviata: $fileName" -ForegroundColor Cyan

        # CopyHere e' asincrono: attende la comparsa del file nella cartella.
        for ($wait = 0; $wait -lt 600; $wait++) {
            Start-Sleep -Milliseconds 500
            $done = $false
            foreach ($candidate in @($folder.Items())) {
                if ($candidate.Name -ieq $fileName) { $done = $true; break }
            }
            if ($done) {
                Write-Host "[TRANSFER] Copia su dispositivo completata: $fileName" -ForegroundColor Green
                return (($devicePath.TrimEnd('\', '/')) + '\' + $fileName)
            }
        }
        Write-Host "[TRANSFER] Timeout in attesa della copia su dispositivo" -ForegroundColor Red
        return $null
    } catch {
        Write-Host "[TRANSFER] Errore copia su dispositivo: $_" -ForegroundColor Red
        return $null
    }
}

# Sposta il file completato nella cartella configurata (config.json), se il
# task ha richiesto il trasferimento. In caso di problemi il file resta in
# downloads/ e viene restituito il percorso originale.
function Move-TransferredFile($task, [string]$filePath) {
    if (-not $task.transfer) { return $filePath }
    if ([string]::IsNullOrWhiteSpace($transferDir)) {
        Write-Host "[TRANSFER] Cartella non configurata in config.json: file lasciato in downloads/" -ForegroundColor Yellow
        return $filePath
    }
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) { return $filePath }

    # Dispositivo portatile/MTP: "Questo PC\Forerunner 745\Internal Storage\..."
    if ($transferDir -match '^(Questo PC|This PC|PC|Computer)[\\/]') {
        $deviceDest = Copy-FileToPortableDevice $filePath $transferDir
        if ($deviceDest) {
            Remove-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
            return $deviceDest
        }
        return $filePath
    }

    try {
        if (!(Test-Path -LiteralPath $transferDir)) {
            New-Item -ItemType Directory -Path $transferDir -Force | Out-Null
        }
        $dest = Join-Path $transferDir ([System.IO.Path]::GetFileName($filePath))
        if (Test-Path -LiteralPath $dest) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
            $ext = [System.IO.Path]::GetExtension($filePath)
            $i = 1
            while (Test-Path -LiteralPath (Join-Path $transferDir "$base`_$i$ext")) { $i++ }
            $dest = Join-Path $transferDir "$base`_$i$ext"
        }
        Move-Item -LiteralPath $filePath -Destination $dest -Force
        Write-Host "[TRANSFER] File spostato in: $dest" -ForegroundColor Green
        return $dest
    } catch {
        Write-Host "[TRANSFER] Spostamento fallito: $_" -ForegroundColor Red
        return $filePath
    }
}

# Elimina i file di log di un task: su disco restano solo i log dei task
# falliti (con errori), mentre quelli completati con successo vengono rimossi.
# Con -OnlyEmpty rimuove solo i file vuoti creati dalla redirezione di
# Start-Process quando non c'e' output da scrivere.
function Remove-TaskLogFiles($task, [switch]$OnlyEmpty) {
    foreach ($f in @($task.logOut, $task.logErr, $task.pathFile, $task.convertLog, $task.convertErr)) {
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { continue }
        if ($OnlyEmpty) {
            try {
                if ((Get-Item -LiteralPath $f).Length -gt 0) { continue }
            } catch { continue }
        }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}

function Set-TaskPhase($task, [string]$phase) {
    $task.phase = $phase
    if (($phase -eq 'completed' -or $phase -eq 'failed') -and -not $task.finishedAt) {
        $task.finishedAt = Get-Date
        if ($phase -eq 'completed') {
            Remove-TaskLogFiles $task
        } else {
            Remove-TaskLogFiles $task -OnlyEmpty
        }
    }
}

# Aggiunge una riga al DB dei download (log\downloads.txt) al termine di un
# download completato al 100%. Se il file e' stato eliminato manualmente o non
# esiste, viene ricreato da zero con la riga di intestazione.
function Add-DownloadHistory([string]$url, [string]$title) {
    $date = Get-Date -Format "yyyyMMddHHmm"
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "" }
    $title = ($title -replace '[\r\n;]', ' ').Trim()
    $line = "$date;$url;$title"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        if (!(Test-Path -LiteralPath $historyFile)) {
            [System.IO.File]::WriteAllText($historyFile, "data;link;titolovideo`r`n", $encoding)
        }
        [System.IO.File]::AppendAllText($historyFile, "$line`r`n", $encoding)
    } catch {
        Write-Host "[HISTORY] Impossibile aggiornare '$historyFile': $_" -ForegroundColor Red
    }
}

# Rimuove task conclusi da piu' di 30 minuti. I file di log dei task falliti
# restano su disco finche' non vengono eliminati manualmente.
function Remove-OldTasks {
    $cutoff = (Get-Date).AddMinutes(-30)
    foreach ($key in @($tasks.Keys)) {
        $task = $tasks[$key]
        if ($task.finishedAt -and $task.finishedAt -lt $cutoff) {
            $tasks.Remove($key)
        }
    }
}

# Verifica l'esito della conversione senza affidarsi a Process.ExitCode:
# in Windows PowerShell 5.1 Start-Process -PassThru non popola ExitCode.
function Test-ConversionSucceeded($task) {
    if (-not $task.tempOutput -or -not (Test-Path -LiteralPath $task.tempOutput)) { return $false }
    try {
        if ((Get-Item -LiteralPath $task.tempOutput).Length -le 0) { return $false }
    } catch {
        return $false
    }
    if ($task.convertErr -and (Test-Path -LiteralPath $task.convertErr)) {
        $errText = (Read-SharedFileLines $task.convertErr) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($errText)) { return $false }
    }
    if ($task.convertLog) {
        $tail = Read-FileTail $task.convertLog 4096
        if ($tail -notmatch 'progress=end') { return $false }
    }
    return $true
}

# Calcola la percentuale di conversione ffmpeg leggendo la coda del progress log.
function Get-ConvertPercent($task) {
    if (-not $task.convertLog -or $task.totalDuration -le 0) { return 0.0 }
    $tail = Read-FileTail $task.convertLog 8192
    if (-not $tail) { return 0.0 }
    $lastUs = [long]0
    foreach ($rawLine in $tail.Split("`n")) {
        $line = $rawLine.Trim()
        if ($line -match '^out_time_us=(\d+)') {
            $lastUs = [long]$matches[1]
        } elseif ($line -match '^out_time_ms=(\d+)') {
            $lastUs = [long]$matches[1]
        } elseif ($line -match '^out_time=(\d+):(\d+):(\d+(?:\.\d+)?)') {
            $seconds = ([long]$matches[1] * 3600) + ([long]$matches[2] * 60) + [double]$matches[3]
            $lastUs = [long]($seconds * 1000000.0)
        }
    }
    if ($lastUs -gt 0) {
        return [Math]::Min(99.9, ($lastUs / ($task.totalDuration * 1000000.0)) * 100.0)
    }
    return 0.0
}

# ---------------------------------------------------------------------------
# Loop principale del server
# ---------------------------------------------------------------------------
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request

        try {
            # CORS Preflight
            if ($request.HttpMethod -eq "OPTIONS") {
                Send-Response $context 200 "text/plain" @()
                continue
            }

            $path = $request.Url.AbsolutePath
            $query = $request.QueryString

            Remove-OldTasks

            # 1. File statici (SPA)
            if ($path -eq "/" -or $path -eq "/index.html") {
                $indexPath = Join-Path $webDir "index.html"
                if (Test-Path -LiteralPath $indexPath) {
                    $htmlBytes = [System.IO.File]::ReadAllBytes($indexPath)
                    Send-Response $context 200 "text/html; charset=utf-8" $htmlBytes
                } else {
                    Send-ErrorJson $context 404 "index.html non trovato in $webDir"
                }
                continue
            }

            # 2. GET /api/info?url=...
            if ($path -eq "/api/info" -and $request.HttpMethod -eq "GET") {
                $targetUrl = $query["url"]
                if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                    Send-ErrorJson $context 400 "Parametro 'url' obbligatorio."
                    continue
                }

                Write-Host "[API] Estrazione JSON metadati per: $targetUrl" -ForegroundColor Yellow

                $result = Invoke-ProcessCapture $ytdlpExe @("-J", "--skip-download", "--no-warnings", $targetUrl)

                if ($result -and $result.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.stdout)) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($result.stdout)
                    Send-Response $context 200 "application/json; charset=utf-8" $bytes
                } else {
                    if (-not $result) {
                        $errMsg = "Impossibile avviare yt-dlp."
                    } elseif ($result.stderr) {
                        $errMsg = $result.stderr
                    } else {
                        $errMsg = "yt-dlp ha terminato con codice $($result.exitCode)"
                    }
                    Write-Host "[API ERRORE] $errMsg" -ForegroundColor Red
                    Send-ErrorJson $context 500 $errMsg
                }
                continue
            }

            # 3. GET /api/raw-formats?url=...
            if ($path -eq "/api/raw-formats" -and $request.HttpMethod -eq "GET") {
                $targetUrl = $query["url"]
                if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                    Send-ErrorJson $context 400 "Parametro 'url' obbligatorio."
                    continue
                }

                Write-Host "[API] Estrazione tabella grezza (-F) per: $targetUrl" -ForegroundColor Yellow

                $result = Invoke-ProcessCapture $ytdlpExe @("-F", "--no-warnings", $targetUrl)
                $raw = ""
                if ($result) { $raw = ($result.stdout + "`n" + $result.stderr).Trim() }

                Send-Json $context 200 @{ raw = $raw }
                continue
            }

            # 4. POST /api/download
            if ($path -eq "/api/download" -and $request.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                try {
                    $bodyObj = $body | ConvertFrom-Json
                } catch {
                    Send-ErrorJson $context 400 "Corpo JSON non valido."
                    continue
                }

                $targetUrl = $bodyObj.url
                $mode = $bodyObj.mode
                $formatId = $bodyObj.formatId
                $formatKind = $bodyObj.formatKind
                $audioFormat = if ($bodyObj.audioFormat) { $bodyObj.audioFormat } else { "mp3" }
                $audioQuality = if ($bodyObj.audioQuality) { $bodyObj.audioQuality } else { "128K" }
                $audioSource = $bodyObj.audioSource
                $videoPreset = $bodyObj.videoPreset
                $container = if ($bodyObj.container) { $bodyObj.container } else { "mp4" }
                $transfer = [bool]$bodyObj.transfer

                if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                    Send-ErrorJson $context 400 "URL non valido."
                    continue
                }

                $taskId = [System.Guid]::NewGuid().ToString()
                $logOut = Join-Path $logDir "task_${taskId}_out.log"
                $logErr = Join-Path $logDir "task_${taskId}_err.log"
                $pathFile = Join-Path $logDir "task_${taskId}_path.txt"

                $argsArray = New-Object System.Collections.Generic.List[string]
                $argsArray.AddRange([string[]]@(
                    "--newline",
                    "--no-warnings",
                    "--retries", "20",
                    "--fragment-retries", "20",
                    "--file-access-retries", "5",
                    "--retry-sleep", "3",
                    "--socket-timeout", "30",
                    "-P", $downloadsDir,
                    "-o", "%(title)s.%(ext)s",
                    "--print-to-file", "after_move:filepath", $pathFile
                ))

                if ($mode -eq "audio") {
                    if ($audioSource -eq "selected" -and -not [string]::IsNullOrWhiteSpace($formatId)) {
                        $argsArray.Add("-f")
                        $argsArray.Add($formatId)
                    } else {
                        $argsArray.Add("-f")
                        $argsArray.Add("ba/bestaudio")
                    }
                    # La conversione separata avviene con ffmpeg. Se ffmpeg non e'
                    # disponibile non possiamo estrarre/convertire l'audio: scarichiamo
                    # il flusso audio originale senza -x (che richiederebbe ffmpeg).
                    if (-not $ffmpegExe) {
                        Write-Host "[DOWNLOAD] FFmpeg assente: verra' scaricato l'audio originale senza conversione." -ForegroundColor Yellow
                    }
                } else {
                    if ($videoPreset -eq "best_mp4") {
                        $argsArray.Add("-f")
                        $argsArray.Add("bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b")
                    } elseif ($videoPreset -eq "best_any") {
                        $argsArray.Add("-f")
                        $argsArray.Add("bv*+ba/b")
                    } elseif (-not [string]::IsNullOrWhiteSpace($formatId)) {
                        $argsArray.Add("-f")
                        if ($formatKind -eq "muxed") {
                            # Il formato scelto contiene gia' audio: unirlo a ba lo duplicherebbe.
                            $argsArray.Add("$formatId/b")
                        } else {
                            $argsArray.Add("$formatId+ba/b")
                        }
                    } else {
                        $argsArray.Add("-f")
                        $argsArray.Add("bv*+ba/b")
                    }
                    $argsArray.Add("--merge-output-format")
                    $argsArray.Add($container)
                }

                $argsArray.Add($targetUrl)

                $dlCmdLine = ConvertTo-CmdLine $argsArray.ToArray()

                Write-Host "[DOWNLOAD] Avvio task ${taskId}: $($argsArray -join ' ')" -ForegroundColor Green

                $proc = Start-Process -FilePath $ytdlpExe -ArgumentList $dlCmdLine -RedirectStandardOutput $logOut -RedirectStandardError $logErr -NoNewWindow -PassThru

                $tasks[$taskId] = @{
                    proc             = $proc
                    dlCmdLine        = $dlCmdLine
                    dlRetries        = 0
                    logOut           = $logOut
                    logErr           = $logErr
                    pathFile         = $pathFile
                    url              = $targetUrl
                    startTime        = (Get-Date)
                    finishedAt       = $null
                    phase            = "downloading"
                    transfer         = $transfer
                    mode             = $mode
                    needsConversion  = ($mode -eq "audio" -and $ffmpegExe)
                    audioFormat      = $audioFormat
                    audioQuality     = $audioQuality
                    convertProc      = $null
                    convertLog       = $null
                    convertErr       = $null
                    totalDuration    = 0.0
                    rawFile          = $null
                    tempOutput       = $null
                    outputFile       = $null
                }

                Send-Json $context 200 @{ taskId = $taskId }
                continue
            }

            # 5. GET /api/progress?id=...
            if ($path -eq "/api/progress" -and $request.HttpMethod -eq "GET") {
                $taskId = $query["id"]
                if ([string]::IsNullOrWhiteSpace($taskId) -or -not $tasks.ContainsKey($taskId)) {
                    Send-ErrorJson $context 404 "Task non trovato."
                    continue
                }

                $t = $tasks[$taskId]

                $lines = Read-SharedFileLines $t.logOut
                $errLines = Read-SharedFileLines $t.logErr
                if ($errLines.Length -gt 0) { $lines = @($lines) + @($errLines) }

                $percent = 0.0
                $speed = ""
                $eta = ""
                $totalSize = ""
                $convertPercent = 0.0

                # Parsing progresso download
                foreach ($line in $lines) {
                    if ($line -match '\[download\]\s+([\d\.]+)%\s+of\s+([^\s]+)\s+at\s+([^\s]+)\s+ETA\s+([^\s]+)') {
                        $percent = [double]$matches[1]
                        $totalSize = $matches[2]
                        $speed = $matches[3]
                        $eta = $matches[4]
                    } elseif ($line -match '\[download\]\s+100%') {
                        $percent = 100.0
                    }
                }

                # Fase: downloading
                if ($t.phase -eq "downloading") {
                    if ($t.proc.HasExited) {
                        $hasError = Test-DownloadLogProblem $lines

                        # Nota: Start-Process -PassThru non popola ExitCode su PS 5.1,
                        # quindi l'esito viene determinato dai log e dal file prodotto.
                        if ($hasError) {
                            Set-TaskPhase $t "failed"
                        } elseif ($t.needsConversion) {
                            $rawFile = Resolve-DownloadedPath $lines $t.startTime $t.pathFile
                            if ($rawFile -and -not (Test-MediaIntegrity $rawFile)) {
                                # Download corrotto/troncato: un solo nuovo tentativo automatico.
                                if ($t.dlRetries -lt 1) {
                                    $t.dlRetries++
                                    Write-Host "[DOWNLOAD] File scaricato corrotto, nuovo tentativo ($($t.dlRetries))..." -ForegroundColor Yellow
                                    Remove-Item -LiteralPath $rawFile -Force -ErrorAction SilentlyContinue
                                    if ($t.pathFile) { Remove-Item -LiteralPath $t.pathFile -Force -ErrorAction SilentlyContinue }
                                    $t.startTime = Get-Date
                                    $t.proc = Start-Process -FilePath $ytdlpExe -ArgumentList $t.dlCmdLine -RedirectStandardOutput $t.logOut -RedirectStandardError $t.logErr -NoNewWindow -PassThru
                                    $t.phase = "downloading"
                                } else {
                                    Set-TaskPhase $t "failed"
                                    Write-Host "[DOWNLOAD] File scaricato corrotto, tentativi esauriti" -ForegroundColor Red
                                }
                            } elseif ($rawFile) {
                                $t.rawFile = $rawFile
                                $t.totalDuration = Get-MediaDuration $rawFile

                                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($rawFile)
                                $finalOutput = Join-Path $downloadsDir "$baseName.$($t.audioFormat)"
                                $tempOutput = Join-Path $downloadsDir "$baseName`.__converting__.$($t.audioFormat)"
                                $convertLog = Join-Path $logDir "task_${taskId}_convert_out.log"
                                $convertErr = Join-Path $logDir "task_${taskId}_convert_err.log"

                                if (Test-Path -LiteralPath $tempOutput) { Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue }

                                $t.outputFile = $finalOutput
                                $t.tempOutput = $tempOutput
                                $t.convertLog = $convertLog
                                $t.convertErr = $convertErr

                                $codecArgs = Get-AudioCodecArgs $t.audioFormat $t.audioQuality
                                $cleanTitle = ConvertTo-CleanTitle $baseName
                                $compatArgs = Get-GarminCompatArgs $t.audioFormat $cleanTitle
                                $ffArgList = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-progress', 'pipe:1', '-i', $rawFile, '-vn') + $codecArgs + $compatArgs + @('-y', $tempOutput)
                                $ffCmdLine = ConvertTo-CmdLine $ffArgList
                                Write-Host "[CONVERT] ffmpeg $ffCmdLine" -ForegroundColor Cyan

                                $convertProc = Start-Process -FilePath $ffmpegExe -ArgumentList $ffCmdLine -RedirectStandardOutput $convertLog -RedirectStandardError $convertErr -NoNewWindow -PassThru
                                $t.convertProc = $convertProc
                                Set-TaskPhase $t "converting"
                            } else {
                                Set-TaskPhase $t "failed"
                                Write-Host "[CONVERT] File scaricato non trovato nei log del task ${taskId}" -ForegroundColor Red
                            }
                        } else {
                            $out = Resolve-DownloadedPath $lines $t.startTime $t.pathFile
                            if ($out) {
                                $out = Rename-SanitizedFile $out
                                $out = Move-TransferredFile $t $out
                                Add-DownloadHistory $t.url ([System.IO.Path]::GetFileNameWithoutExtension($out))
                                Set-TaskPhase $t "completed"
                                $percent = 100.0
                            } else {
                                Set-TaskPhase $t "failed"
                                Write-Host "[DOWNLOAD] File scaricato non trovato nei log del task ${taskId}" -ForegroundColor Red
                            }
                        }
                    }
                }

                # Fase: converting (ffmpeg in esecuzione)
                if ($t.phase -eq "converting") {
                    if ($t.convertProc -and -not $t.convertProc.HasExited) {
                        $convertPercent = Get-ConvertPercent $t
                    } elseif ($t.convertProc -and $t.convertProc.HasExited) {
                        if ((Test-ConversionSucceeded $t) -and (Test-MediaIntegrity $t.tempOutput)) {
                            $moved = $false
                            if ($t.tempOutput -and (Test-Path -LiteralPath $t.tempOutput)) {
                                try {
                                    Move-Item -LiteralPath $t.tempOutput -Destination $t.outputFile -Force
                                    $moved = $true
                                } catch {
                                    Write-Host "[CONVERT] Impossibile rinominare l'output: $_" -ForegroundColor Red
                                }
                            }
                            if ($moved) {
                                # Il file sorgente si elimina solo dopo il buon esito
                                # dello spostamento, cosi' un errore non causa perdita dati.
                                if ($t.rawFile -and (Test-Path -LiteralPath $t.rawFile)) {
                                    Remove-Item -LiteralPath $t.rawFile -Force -ErrorAction SilentlyContinue
                                }
                                $t.outputFile = Rename-SanitizedFile $t.outputFile
                                Move-TransferredFile $t $t.outputFile | Out-Null
                                Add-DownloadHistory $t.url ([System.IO.Path]::GetFileNameWithoutExtension($t.outputFile))
                                Set-TaskPhase $t "completed"
                                $convertPercent = 100.0
                                Write-Host "[CONVERT] Conversione completata con successo" -ForegroundColor Green
                            } else {
                                Set-TaskPhase $t "failed"
                                if ($t.tempOutput -and (Test-Path -LiteralPath $t.tempOutput)) {
                                    Remove-Item -LiteralPath $t.tempOutput -Force -ErrorAction SilentlyContinue
                                }
                                Write-Host "[CONVERT] Impossibile spostare l'output convertito" -ForegroundColor Red
                            }
                        } else {
                            Set-TaskPhase $t "failed"
                            if (Test-Path -LiteralPath $t.tempOutput) {
                                Remove-Item -LiteralPath $t.tempOutput -Force -ErrorAction SilentlyContinue
                            }
                            Write-Host "[CONVERT] Conversione fallita o output non integro" -ForegroundColor Red
                            if ($t.convertErr) {
                                $convErrLines = Read-SharedFileLines $t.convertErr
                                foreach ($el in $convErrLines) { $lines = @($lines) + @("[ffmpeg] $el") }
                            }
                        }
                    } else {
                        Set-TaskPhase $t "failed"
                    }
                }

                $phase = $t.phase

                # Progresso complessivo 0-100: quando e' prevista la conversione
                # il download pesa per il primo 50% e ffmpeg per il restante 50%.
                $overallPercent = $percent
                if ($t.needsConversion) {
                    if ($t.convertProc) {
                        $overallPercent = 50.0 + ($convertPercent * 0.5)
                    } else {
                        $overallPercent = $percent * 0.5
                    }
                }

                $respObj = @{
                    phase          = $phase
                    overallPercent = $overallPercent
                    speed          = $speed
                    eta            = $eta
                    totalSize      = $totalSize
                    logs           = $lines
                }
                Send-Json $context 200 $respObj
                continue
            }

            # 6. POST /api/open-folder
            if ($path -eq "/api/open-folder" -and $request.HttpMethod -eq "POST") {
                Start-Process "explorer.exe" -ArgumentList (ConvertTo-CmdArg $downloadsDir)
                Send-Json $context 200 @{ success = $true }
                continue
            }

            # 6b. GET /api/config
            if ($path -eq "/api/config" -and $request.HttpMethod -eq "GET") {
                Send-Json $context 200 @{
                    transferDirectory = $transferDir
                    transferEnabled   = -not [string]::IsNullOrWhiteSpace($transferDir)
                }
                continue
            }

            # 7. GET /api/check-update
            if ($path -eq "/api/check-update" -and $request.HttpMethod -eq "GET") {
                Write-Host "[API] Controllo aggiornamenti yt-dlp..." -ForegroundColor Yellow
                try {
                    $result = Invoke-ProcessCapture $ytdlpExe @("--version")
                    if (-not $result) { throw "Impossibile avviare yt-dlp." }
                    $currentVersion = $result.stdout.Trim()

                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" -UseBasicParsing
                    $latestVersion = $release.tag_name

                    $updateAvailable = $currentVersion -ne $latestVersion

                    Write-Host "[API] Versione corrente: $currentVersion | Ultima stabile: $latestVersion | Aggiornamento: $updateAvailable" -ForegroundColor Cyan

                    Send-Json $context 200 @{
                        currentVersion  = $currentVersion
                        latestVersion   = $latestVersion
                        updateAvailable = $updateAvailable
                    }
                } catch {
                    Write-Host "[API ERRORE] Controllo aggiornamenti fallito: $_" -ForegroundColor Red
                    Send-ErrorJson $context 500 "Impossibile controllare gli aggiornamenti: $($_.Exception.Message)"
                }
                continue
            }

            # 8. POST /api/update
            if ($path -eq "/api/update" -and $request.HttpMethod -eq "POST") {
                Write-Host "[API] Avvio aggiornamento yt-dlp..." -ForegroundColor Yellow
                try {
                    $result = Invoke-ProcessCapture $ytdlpExe @("--update-to", "stable")
                    if (-not $result) { throw "Impossibile avviare yt-dlp." }

                    $exitCode = $result.exitCode
                    $output = ($result.stdout + "`n" + $result.stderr).Trim()

                    Write-Host "[API] Aggiornamento completato. Exit code: $exitCode" -ForegroundColor Green
                    Write-Host "[API] Output: $output" -ForegroundColor Gray

                    Send-Json $context 200 @{
                        success = ($exitCode -eq 0)
                        output  = $output
                    }
                } catch {
                    Write-Host "[API ERRORE] Aggiornamento fallito: $_" -ForegroundColor Red
                    Send-ErrorJson $context 500 "Aggiornamento fallito: $($_.Exception.Message)"
                }
                continue
            }

            Send-ErrorJson $context 404 "Endpoint non trovato."
        } catch {
            Write-Host "[SERVER ERRORE] $_" -ForegroundColor Red
            Send-ErrorJson $context 500 $_.Exception.Message
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "Server arrestato." -ForegroundColor Gray
}
