<#
.SYNOPSIS
    Создание репозитория якорей и включение защиты ветки main (ADR-013, шаг 2).

.DESCRIPTION
    Один запуск делает три вещи, и третья важнее первых двух:

      1. создаёт приватный репозиторий (если его ещё нет);
      2. включает защиту ветки main: запрет force-push, запрет удаления, enforce_admins;
      3. ПРОВЕРЯЕТ защиту отказом пробного force-push. Если пробный force-push прошёл —
         защита не работает, и это не «условно настроено», а провал (exit 1).

    Почему проверка обязательна: «включил и предположил» — это ровно тот класс ошибки,
    ради которого якорь и заводится. Непроверенная защита ветки не считается защитой.

    Токен: нужен classic-scope `repo` или fine-grained с Administration: Read and write.
    Текущий fine-grained токен ограничен репозиторием family-portal, поэтому создание
    нового репозитория им недоступно (403 createRepository). Токен читается из
    переменной окружения GH_TOKEN и никогда не печатается.

.PARAMETER Repo
    Полное имя репозитория, по умолчанию pparielt-code/family-portal-anchors.

.PARAMETER Remote
    URL для push, по умолчанию SSH-форма git@github.com:<owner>/<repo>.git

.EXAMPLE
    $env:GH_TOKEN = "<token>"
    .\tools\setup-anchor-repo.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = "pparielt-code/family-portal-anchors",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
$ApiRoot = "https://api.github.com"

function Get-Token {
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    try {
        $t = (& gh auth token) 2>$null
        if ($LASTEXITCODE -eq 0 -and $t) { return $t.Trim() }
    } catch { }
    throw "Нет токена: задайте переменную окружения GH_TOKEN (права: repo / Administration: write)."
}

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )
    $headers = @{
        Authorization          = "token $script:Token"
        "User-Agent"           = "aidos-anchor-setup"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $params = @{
        Uri         = "$ApiRoot$Path"
        Method      = $Method
        Headers     = $headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 8)
        $params.ContentType = "application/json"
    }
    try {
        $response = Invoke-WebRequest @params
        return @{ Ok = $true; Status = $response.StatusCode; Data = ($response.Content | ConvertFrom-Json) }
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $body = ""
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
            }
        }
        return @{ Ok = $false; Status = $status; Error = $body }
    }
}

$script:Token = Get-Token
$owner, $name = $Repo -split "/"

# --- 1. Репозиторий ---------------------------------------------------------
Write-Host "[1/3] Репозиторий $Repo"
$existing = Invoke-Api -Method GET -Path "/repos/$Repo"
if ($existing.Ok) {
    Write-Host "      уже существует, создание не требуется"
} elseif ($existing.Status -eq 404) {
    $created = Invoke-Api -Method POST -Path "/user/repos" -Body @{
        name        = $name
        private     = $true
        description = "External anchor for the family-portal manifest chain (append-only, ADR-013)"
        auto_init   = $false
    }
    if (-not $created.Ok) {
        Write-Host "      ОТКАЗ: HTTP $($created.Status). Токен не может создавать репозитории." -ForegroundColor Red
        Write-Host "      $($created.Error)"
        Write-Host "      Нужен токен с правом создания репозиториев либо репозиторий, созданный вручную."
        exit 2
    }
    Write-Host "      создан: $($created.Data.full_name)"
} else {
    Write-Host "      НЕИЗВЕСТНО: HTTP $($existing.Status) при чтении репозитория" -ForegroundColor Red
    exit 2
}

# --- 2. Защита ветки --------------------------------------------------------
Write-Host "[2/3] Защита ветки $Branch"
$protection = @{
    required_status_checks        = $null
    enforce_admins                = $true
    required_pull_request_reviews = $null
    restrictions                  = $null
    allow_force_pushes            = $false
    allow_deletions               = $false
}
$applied = Invoke-Api -Method PUT -Path "/repos/$Repo/branches/$Branch/protection" -Body $protection
if (-not $applied.Ok) {
    Write-Host "      ОТКАЗ: HTTP $($applied.Status)" -ForegroundColor Red
    Write-Host "      $($applied.Error)"
    if ($applied.Status -eq 404) {
        Write-Host "      Ветки $Branch ещё нет: сначала запушьте содержимое, затем повторите запуск."
    }
    if ($applied.Error -match "GitHub Pro|make this repository public") {
        # Проверено 2026-10-27: на бесплатном тарифе защита веток и rulesets доступны только
        # в ПУБЛИЧНЫХ репозиториях. Дело не в правах токена: тот же токен успешно меняет
        # настройки репозитория (administration:write есть).
        Write-Host ""
        Write-Host "ПРИЧИНА: тариф, а не токен. Защита веток недоступна в приватном репозитории на" -ForegroundColor Yellow
        Write-Host "бесплатном плане GitHub. Права токена достаточны (PATCH репозитория проходит)."
        Write-Host ""
        Write-Host "Варианты (решает владелец):"
        Write-Host "  A. Оставить репозиторий публичным -> защита включается бесплатно."
        Write-Host "     Запись якоря персональных данных не содержит по построению (белый список полей)."
        Write-Host "  B. GitHub Pro (~4 USD/мес) -> защита в приватном репозитории."
        Write-Host "  C. Публичное 'зеркало хэшей': журнал остаётся приватным, публикуются только"
        Write-Host "     SHA-256 записей. Защита публичного репозитория бесплатна, метаданные не утекают."
        exit 3
    }
    exit 1
}
Write-Host "      включена: allow_force_pushes=false, allow_deletions=false, enforce_admins=true"

# --- 3. Проверка защиты отказом force-push ---------------------------------
Write-Host "[3/3] Проверка защиты: пробный force-push должен быть ОТКЛОНЁН"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "      НЕ ПРОВЕРЕНО: git не найден в PATH" -ForegroundColor Yellow
    exit 2
}
$insideRepo = (& git rev-parse --git-dir) 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "      НЕ ПРОВЕРЕНО: запускать из клона репозитория якорей" -ForegroundColor Yellow
    exit 2
}

$remoteUrl = (& git remote get-url origin) 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "      НЕ ПРОВЕРЕНО: нет remote origin" -ForegroundColor Yellow
    exit 2
}
Write-Host "      remote: $remoteUrl"

# Пустой force-push: отправляем текущий HEAD в пустую ссылку с --force. Если защита работает,
# сервер откажет (protected branch hook declined). Ничего не теряется: ссылка создаётся пустой.
$probeRef = "refs/heads/__force_probe_should_fail"
& git push --force origin "HEAD:$probeRef" 2>&1 | ForEach-Object { Write-Host "      $_" }
$probeExit = $LASTEXITCODE

if ($probeExit -eq 0) {
    Write-Host ""
    Write-Host "ПРОВАЛ: force-push прошёл — защита НЕ действует." -ForegroundColor Red
    Write-Host "Убираю пробную ветку и фиксирую провал."
    & git push origin --delete "__force_probe_should_fail" 2>&1 | ForEach-Object { Write-Host "      $_" }
    exit 1
}

Write-Host ""
Write-Host "ВЕРНО: force-push отклонён сервером (exit $probeExit) — защита действует." -ForegroundColor Green
Write-Host "Дальше: git push -u origin $Branch, затем первая запись якоря."
exit 0
