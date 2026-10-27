<#
.SYNOPSIS
    Создание репозитория якорей и включение защиты ветки main (ADR-013, шаг 2).

.DESCRIPTION
    Один запуск делает три вещи, и третья важнее первых двух:

      1. создаёт репозиторий (по умолчанию ПУБЛИЧНЫЙ, см. .PARAMETER Visibility);
      2. включает защиту ветки main: запрет force-push, запрет удаления, enforce_admins;
      3. ПРОВЕРЯЕТ защиту отказом пробного force-push. Если пробный force-push прошёл —
         защита не работает, и это не «условно настроено», а провал (exit 1).

    Почему проверка обязательна: «включил и предположил» — это ровно тот класс ошибки,
    ради которого якорь и заводится. Непроверенная защита ветки не считается защитой.

    Почему публичный по умолчанию: на бесплатном плане GitHub защита веток есть ТОЛЬКО в
    публичных репозиториях (в приватном — 403 Upgrade to GitHub Pro ...). Проверено 2026-10-27:
    права токена достаточны (тот же токен меняет настройки репозитория), ограничение тарифное.
    Раскрывать нечего: запись якоря собирается по белому списку полей и персональных данных
    не содержит.

    Токен: classic-scope `repo` либо fine-grained с Administration: Read and write + право
    создавать репозитории. Токен читается из переменной окружения GH_TOKEN и никогда не печатается.

.PARAMETER Repo
    Полное имя репозитория, по умолчанию pparielt-code/family-portal-anchors.

.PARAMETER Visibility
    public (по умолчанию) или private. При private на бесплатном плане защита не включится —
    скрипт скажет об этом отдельно (exit 3), а не выдаст общий отказ.

.PARAMETER Remote
    URL для push, по умолчанию SSH-форма git@github.com:<owner>/<repo>.git

.EXAMPLE
    $env:GH_TOKEN = "<token>"
    .\tools\setup-anchor-repo.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = "pparielt-code/family-portal-anchors",
    [string]$Branch = "main",
    [ValidateSet("public", "private")]
    [string]$Visibility = "public"
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
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = $_.ErrorDetails.Message
        }
        if (-not $body -and $_.Exception.Response) {
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
        private     = ($Visibility -eq "private")
        description = "External anchor for the family-portal manifest chain (append-only, ADR-013)"
        auto_init   = $false
    }
    if (-not $created.Ok) {
        Write-Host "      ОТКАЗ: HTTP $($created.Status). Токен не может создавать репозитории." -ForegroundColor Red
        Write-Host "      $($created.Error)"
        Write-Host "      Нужен токен с правом создания репозиториев либо репозиторий, созданный вручную."
        exit 2
    }
    Write-Host "      создан: $($created.Data.full_name) (visibility $($created.Data.visibility))"
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
        Write-Host "ПРИЧИНА: тариф, а не токен. Права токена достаточны (PATCH репозитория проходит)."
        Write-Host "Проверьте видимость репозитория: защита веток на бесплатном плане GitHub есть" -ForegroundColor Yellow
        Write-Host "только в публичных репозиториях, в приватных — нет."
        Write-Host ""
        Write-Host "Что делать:"
        Write-Host "  A. Сделать репозиторий публичным и повторить запуск:"
        Write-Host "     GitHub -> Settings -> Danger Zone -> Change visibility -> Change to public."
        Write-Host "     Запись якоря персональных данных не содержит по построению (белый список полей),"
        Write-Host "     поэтому публичность ничего не раскрывает, кроме числа и времени импортов."
        Write-Host "  B. GitHub Pro (~4 USD/мес) -> защита доступна и в приватном репозитории."
        exit 3
    }
    exit 1
}
Write-Host "      включена: allow_force_pushes=false, allow_deletions=false, enforce_admins=true"

# --- 3. Проверка защиты отказом -------------------------------------------------
# Проба обязана бить ПО ЗАЩИЩЁННОЙ ВЕТКЕ. Проверка «пуш в другую ветку отклонён» ничего не
# доказывает: защита настроена на refs/heads/main, а новый ref никто не защищает — такая проба
# проходит и даёт ложный вывод «защита не работает» (дефект был в первой версии скрипта).
#
# Поэтому: пробуем force-push одиночного коммита в main.
#   - отклонено  -> защита действует (то, что нужно);
#   - прошло     -> защиты нет; немедленно восстанавливаем main на сохранённый SHA и падаем.
# Восстановление возможно именно потому, что защиты нет, — то есть успешный путь пробы не
# оставляет испорченной истории. SHA печатается: даже при сбое восстановления он даёт ручной откат.
Write-Host "[3/3] Проверка защиты: пробный force-push в $Branch должен быть ОТКЛОНЁН"
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

$lsOut = (& git ls-remote origin "refs/heads/$Branch") 2>$null
if ($LASTEXITCODE -ne 0 -or -not $lsOut) {
    Write-Host "      НЕ ПРОВЕРЕНО: не удалось прочитать refs/heads/$Branch на origin" -ForegroundColor Yellow
    Write-Host "      Сначала запушьте содержимое: git push -u origin $Branch"
    exit 2
}
$origSha = ($lsOut -split "\s+")[0]
Write-Host "      текущий $Branch на origin: $origSha"

# Одиночный коммит-проба: дерево берём из HEAD, но БЕЗ родителей — им нельзя «дополнить»
# историю, только перезаписать её, что и должно быть отклонено.
$probeTree = (& git rev-parse "HEAD^{tree}") 2>$null
if ($LASTEXITCODE -ne 0 -or -not $probeTree) {
    Write-Host "      НЕ ПРОВЕРЕНО: не удалось прочитать дерево HEAD" -ForegroundColor Yellow
    exit 2
}
$probeCommit = ("anchor protection probe: must never reach $Branch" | & git -c user.name="anchor-probe" -c user.email="anchor-probe@example.invalid" commit-tree $probeTree) 2>$null
if ($LASTEXITCODE -ne 0 -or -not $probeCommit) {
    Write-Host "      НЕ ПРОВЕРЕНО: git commit-tree не отработал" -ForegroundColor Yellow
    exit 2
}
Write-Host "      пробный коммит: $probeCommit"

# Вывод git пишем в файлы и на время вызова снимаем Stop: при $ErrorActionPreference="Stop"
# stderr внешней команды превращается в исключение, и отказ сервера (то есть УСПЕХ пробы)
# выглядел бы как падение скрипта.
$probeOut = [IO.Path]::GetTempFileName()
$probeErr = [IO.Path]::GetTempFileName()
$eap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& git push --force origin "$($probeCommit):refs/heads/$Branch" > $probeOut 2> $probeErr
$probeExit = $LASTEXITCODE
$ErrorActionPreference = $eap
foreach ($f in @($probeOut, $probeErr)) {
    if (Test-Path $f) {
        Get-Content $f | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "      $_" }
    }
}
Remove-Item $probeOut, $probeErr -ErrorAction SilentlyContinue

if ($probeExit -ne 0) {
    Write-Host ""
    Write-Host "ВЕРНО: force-push в $Branch отклонён (exit $probeExit) — защита действует." -ForegroundColor Green
    Write-Host "Дальше: первая запись якоря (tools/record-anchor.mjs)."
    exit 0
}

Write-Host ""
Write-Host "ПРОВАЛ: force-push в $Branch ПРОШЁЛ — защиты нет." -ForegroundColor Red
Write-Host "Восстанавливаю $Branch на $origSha."
$restoreOut = [IO.Path]::GetTempFileName()
$restoreErr = [IO.Path]::GetTempFileName()
$eap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& git push --force origin "$($origSha):refs/heads/$Branch" > $restoreOut 2> $restoreErr
$restoreExit = $LASTEXITCODE
$ErrorActionPreference = $eap
foreach ($f in @($restoreOut, $restoreErr)) {
    if (Test-Path $f) {
        Get-Content $f | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "      $_" }
    }
}
Remove-Item $restoreOut, $restoreErr -ErrorAction SilentlyContinue

$nowOut = (& git ls-remote origin "refs/heads/$Branch") 2>$null
$nowSha = if ($nowOut) { ($nowOut -split "\s+")[0] } else { "" }
if ($restoreExit -eq 0 -and $nowSha -eq $origSha) {
    Write-Host "Восстановлено: $Branch снова $origSha. Записи якоря не потеряны." -ForegroundColor Yellow
    exit 1
}

Write-Host "ВОССТАНОВИТЬ НЕ УДАЛОСЬ. $Branch сейчас: '$nowSha', нужен $origSha." -ForegroundColor Red
Write-Host "Откат вручную: git push --force origin '$($origSha):refs/heads/$Branch'"
exit 2
