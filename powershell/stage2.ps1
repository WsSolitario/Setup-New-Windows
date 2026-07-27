$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ApiBaseUrl = '{{API_BASE_URL}}'
$SetupToken = '{{SETUP_TOKEN}}'
$SetupDirectory = Join-Path $env:ProgramData 'WorkstationSetup'
$NinitePath = Join-Path $SetupDirectory 'ninite.exe'
$TaskName = 'WorkstationSetup-Stage2'
$mutex = $null
$hasMutex = $false
$completed = $false
$transcriptStarted = $false

function Invoke-SetupApi {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Body
    )

    Invoke-RestMethod -Uri "$ApiBaseUrl$Path" -Method Post -Headers @{ 'X-Setup-Token' = $SetupToken } `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress)
}

function Get-ComputerSerialNumber {
    try {
        return (Get-WmiObject win32_bios | Select-Object -ExpandProperty SerialNumber).Trim()
    }
    catch {
        return (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
    }
}

function Test-RebootRequired {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    return ($paths | Where-Object { Test-Path $_ }).Count -gt 0
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'La fase 2 requiere privilegios de administrador.'
    }

    $mutex = [Threading.Mutex]::new($false, 'Global\WorkstationSetupStage2')
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        exit 0
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -Path $SetupDirectory -ItemType Directory -Force | Out-Null
    Start-Transcript -Path (Join-Path $SetupDirectory 'stage2.log') -Append | Out-Null
    $transcriptStarted = $true
    $SerialNumber = Get-ComputerSerialNumber

    Invoke-SetupApi -Path '/api/status' -Body @{
        serial_number = $SerialNumber
        status        = 'instalando_ninite'
    } | Out-Null

    Invoke-WebRequest -Uri "$ApiBaseUrl/ninite.exe" -Headers @{ 'X-Setup-Token' = $SetupToken } -OutFile $NinitePath -UseBasicParsing
    $NiniteProcess = Start-Process -FilePath $NinitePath -ArgumentList '/silent' -Wait -PassThru
    if ($NiniteProcess.ExitCode -ne 0) {
        throw "Ninite termino con el codigo $($NiniteProcess.ExitCode)."
    }

    Invoke-SetupApi -Path '/api/status' -Body @{
        serial_number = $SerialNumber
        status        = 'instalando_actualizaciones'
    } | Out-Null

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Install-Module -Name PSWindowsUpdate -Repository PSGallery -Force -AllowClobber -Scope AllUsers
    }
    Import-Module PSWindowsUpdate -Force
    Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot -Confirm:$false -ErrorAction Stop

    $RebootRequired = Test-RebootRequired
    Invoke-SetupApi -Path '/api/status' -Body @{
        serial_number = $SerialNumber
        status        = 'actualizado'
    } | Out-Null
    $completed = $true

    $WinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $WinlogonPath -Name 'AutoAdminLogon' -Value '0' -Type String
    Remove-ItemProperty -Path $WinlogonPath -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    Remove-Item -Path $NinitePath -Force -ErrorAction SilentlyContinue
    Write-Host 'Configuracion finalizada correctamente.' -ForegroundColor Green
    & msg.exe '*' 'Configuracion finalizada correctamente. El inicio de sesion automatico ha sido deshabilitado.' 2>$null

    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        $transcriptStarted = $false
    }
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue

    if ($RebootRequired) {
        Restart-Computer -Force
    }
}
catch {
    $message = $_.Exception.Message
    Write-Error "Error en la fase 2: $message"
    try {
        if ($SerialNumber) {
            Invoke-SetupApi -Path '/api/status' -Body @{
                serial_number = $SerialNumber
                status        = 'error_fase_2'
            } | Out-Null
        }
    }
    catch {
        Write-Warning "No se pudo informar el error a la API: $($_.Exception.Message)"
    }
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    if ($hasMutex -and $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}

if (-not $completed) {
    exit 1
}
