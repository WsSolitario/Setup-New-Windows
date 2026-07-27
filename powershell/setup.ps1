$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ApiBaseUrl = '{{API_BASE_URL}}'
$LocalUserName = '{{LOCAL_ADMIN_USERNAME}}'
$LocalUserFullName = '{{LOCAL_ADMIN_FULL_NAME}}'
$LocalUserPassword = '{{LOCAL_ADMIN_PASSWORD}}'
$SetupDirectory = Join-Path $env:ProgramData 'WorkstationSetup'
$Stage2Path = Join-Path $SetupDirectory 'stage2.ps1'
$TaskName = 'WorkstationSetup-Stage2'

function Invoke-SetupApi {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Body
    )

    Invoke-RestMethod -Uri "$ApiBaseUrl$Path" -Method Post `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress)
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'La fase 1 debe ejecutarse desde una consola elevada.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -Path $SetupDirectory -ItemType Directory -Force | Out-Null
    Start-Transcript -Path (Join-Path $SetupDirectory 'stage1.log') -Append | Out-Null

    try {
        $SerialNumber = (Get-WmiObject win32_bios | Select-Object -ExpandProperty SerialNumber).Trim()
    }
    catch {
        $SerialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
        throw 'No se pudo obtener el numero de serie del equipo.'
    }

    $Hostname = $env:COMPUTERNAME
    Invoke-SetupApi -Path '/api/register' -Body @{
        serial_number = $SerialNumber
        hostname      = $Hostname
    } | Out-Null

    $SecurePassword = ConvertTo-SecureString $LocalUserPassword -AsPlainText -Force
    $ExistingUser = Get-LocalUser -Name $LocalUserName -ErrorAction SilentlyContinue
    if ($ExistingUser) {
        Set-LocalUser -Name $LocalUserName -Password $SecurePassword -FullName $LocalUserFullName
        Enable-LocalUser -Name $LocalUserName
    }
    else {
        New-LocalUser -Name $LocalUserName -Password $SecurePassword `
            -FullName $LocalUserFullName -Description 'Administrador local de preconfiguracion' `
            -PasswordNeverExpires | Out-Null
    }

    $AdministratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544'
    $IsAdministrator = Get-LocalGroupMember -Group $AdministratorsGroup.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "\\$([regex]::Escape($LocalUserName))$" }
    if (-not $IsAdministrator) {
        Add-LocalGroupMember -Group $AdministratorsGroup.Name -Member $LocalUserName
    }

    $WinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $WinlogonPath -Name 'AutoAdminLogon' -Value '1' -Type String
    Set-ItemProperty -Path $WinlogonPath -Name 'DefaultUserName' -Value $LocalUserName -Type String
    Set-ItemProperty -Path $WinlogonPath -Name 'DefaultPassword' -Value $LocalUserPassword -Type String
    Set-ItemProperty -Path $WinlogonPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String

    $OobePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'
    New-Item -Path $OobePath -Force | Out-Null
    New-ItemProperty -Path $OobePath -Name 'BypassNRO' -Value 1 -PropertyType DWord -Force | Out-Null

    Invoke-WebRequest -Uri "$ApiBaseUrl/stage2.ps1" -OutFile $Stage2Path -UseBasicParsing
    Unblock-File -Path $Stage2Path

    $Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Stage2Path`""
    $LocalUserId = "$env:COMPUTERNAME\$LocalUserName"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $LocalUserId
    $Principal = New-ScheduledTaskPrincipal -UserId $LocalUserId -LogonType Interactive -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null

    Invoke-SetupApi -Path '/api/status' -Body @{
        serial_number = $SerialNumber
        status        = 'fase_1_completada'
    } | Out-Null

    Write-Host 'Fase 1 completada. El equipo se reiniciara en 10 segundos.' -ForegroundColor Green
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
catch {
    Write-Error "Error en la fase 1: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch { }
    throw
}
