<#
  Скрипт: add-scans.ps1

  Логика:
  1) Спросить GitLab URL, PAT и путь к проекту (mygroup/myproject).
  2) Считать .gitlab-ci.yml (если существует).
  3) Найти строку "docker build" и распарсить:
     - "-t <IMAGE>" → CS_IMAGE
     - "-f <DOCKERFILE>" → CS_DOCKERFILE_PATH
     - путь сборки (последний аргумент, если не начинается с '-') → игнорируем или используем на усмотрение.
  4) Добавить/обновить SAST + Container Scanning.
     - Стадию 'test' вставляем *после* 'build', если 'build' есть. Иначе добавляем 'test' в конец.
     - В container_scanning добавляем variables: GIT_STRATEGY=fetch.
     - В секцию variables добавляем CS_IMAGE, CS_REGISTRY и CS_DOCKERFILE_PATH.
  5) Сохранить .gitlab-ci.yml, закоммитить в GitLab.
  6) При желании создать CI/CD переменные CS_REGISTRY_USER / CS_REGISTRY_PASSWORD через API.
#>

Write-Host "=== Настройка GitLab подключения ==="
$gitlabUrlDefault = "https://mygitlab.tehlab.org:9443"
$gitlabUrl = Read-Host "Введите GitLab URL (по умолчанию: $gitlabUrlDefault)"
if ([string]::IsNullOrWhiteSpace($gitlabUrl)) {
    $gitlabUrl = $gitlabUrlDefault
}
Write-Host "GitLab URL = $gitlabUrl"

# Запрос PAT
$secureToken = Read-Host "Введите ваш Personal Access Token (PAT)" -AsSecureString
if (-not $secureToken) {
    Write-Host "Токен не задан. Завершаем." -ForegroundColor Yellow
    return
}
$accessToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
)

# Запрос пути к проекту
$projectPath = Read-Host "Введите путь к проекту (например, mygroup/myproject)"
if ([string]::IsNullOrWhiteSpace($projectPath)) {
    Write-Host "Путь к проекту не указан. Завершаем." -ForegroundColor Yellow
    return
}
$encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
Write-Host "Encoded project path: $encodedProjectPath"

# Заголовки для API
$headers = @{
    'Authorization' = "Bearer $accessToken"
}

# Получаем проект
$apiUrl = "$gitlabUrl/api/v4/projects/$encodedProjectPath"
try {
    $project = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
} catch {
    Write-Host "Ошибка получения проекта: $($_.Exception.Message)" -ForegroundColor Red
    return
}
Write-Host "`nИнформация о проекте:"
$project | Format-List

# Путь к .gitlab-ci.yml
$filePath = ".gitlab-ci.yml"
$encodedFilePath = [System.Uri]::EscapeDataString($filePath)
$apiUrlCiFile = "$gitlabUrl/api/v4/projects/$($project.id)/repository/files/$($encodedFilePath)?ref=$($project.default_branch)"

# Пытаемся скачать .gitlab-ci.yml
$currentContent = ""
try {
    $fileResponse = Invoke-RestMethod -Uri $apiUrlCiFile -Headers $headers -Method Get
    $currentContent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fileResponse.content))
    Write-Host "`nФайл .gitlab-ci.yml получен, размер: $($currentContent.Length) символов."
} catch {
    Write-Host "`nВероятно, .gitlab-ci.yml пока не существует. Начинаем с пустого." -ForegroundColor Yellow
}

# --- 1. Парсинг docker build ---
# Ищем строку "docker build <args>"
# Считаем, что строка заканчивается в конце или на символ \n
# Используем Regex, чтобы вытащить всё после "docker build"
$buildPattern = 'docker\s+build\s+(.*)'
$buildMatch   = [System.Text.RegularExpressions.Regex]::Match($currentContent, $buildPattern, 'IgnoreCase')
$csImage = "your-docker-image:latest"
$csRegistry = '$CI_REGISTRY'
$csDockerfile = "Dockerfile" # по умолчанию

if ($buildMatch.Success) {
    $allBuildArgs = $buildMatch.Groups[1].Value.Trim()
    Write-Host "Найдена строка docker build: $($buildMatch.Value)"

    # Разделим на токены (упрощённо, без учёта сложных кавычек)
    $tokens = $allBuildArgs -split '\s+'
    # Пример: ["-f","Dockerfile.sub","-t","$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA","./subdir"]

    # Пробежимся по токенам
    for ($i=0; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        switch -Regex ($tok) {
            '^-t$' {
                # Следующий токен — наш IMAGE
                if ($i + 1 -lt $tokens.Count) {
                    $csImage = $tokens[$i + 1]
                }
            }
            '^-f$' {
                # Следующий — Dockerfile
                if ($i + 1 -lt $tokens.Count) {
                    $csDockerfile = $tokens[$i + 1]
                }
            }
            default {
                # Если это последний токен, не начинается с '-', может быть путь сборки
                # Но здесь пока не используем
            }
        }
    }

    Write-Host "Извлечено: CS_IMAGE=$csImage ; CS_DOCKERFILE_PATH=$csDockerfile"
} else {
    Write-Host "Не найдена строка 'docker build'. Используем значения по умолчанию."
}

# --- 2. Подготавливаем YAML ---
try {
    $currentYaml = ConvertFrom-Yaml $currentContent -Ordered
} catch {
    Write-Host "Не удалось разобрать YAML, начинаем с пустого." -ForegroundColor Yellow
    $currentYaml = [ordered]@{}
}
if (-not $currentYaml) {
    $currentYaml = [ordered]@{}
}
if (-not ($currentYaml -is [System.Collections.Specialized.OrderedDictionary])) {
    $currentYaml = [ordered]@{}
}

$newYaml = [ordered]@{}

Write-Host "`n=== Добавление секции SAST и модификация stages ==="

# --- 3. Секция stages: вставляем 'test' после 'build' ---
if ($currentYaml.Contains('stages')) {
    $stages = $currentYaml['stages']
    if (-not ($stages -is [System.Collections.IList])) {
        $stages = @($stages)
    }
    if ($stages -contains 'build') {
        $buildIndex = $stages.IndexOf('build')
        if (-not ($stages -contains 'test')) {
            # вставляем 'test' после buildIndex
            $stages = $stages[0..$buildIndex] + @('test') + $stages[($buildIndex + 1)..($stages.Count -1)]
        }
    } else {
        # нет build
        if (-not ($stages -contains 'test')) {
            $stages += 'test'
        }
    }
    $newYaml['stages'] = $stages
    $currentYaml.Remove('stages')
} else {
    # нет секции stages — создаём
    $newYaml['stages'] = @('build','test')
}

# 4. default (переносим как есть, если существует)
if ($currentYaml.Contains('default')) {
    $newYaml['default'] = $currentYaml['default']
    $currentYaml.Remove('default')
}

# 5. include (SAST)
$sastTemplate = @{ 'template' = 'Security/SAST.gitlab-ci.yml' }
if ($currentYaml.Contains('include')) {
    $include = $currentYaml['include']
    if ($include -isnot [System.Collections.IEnumerable]) {
        $include = @($include)
    }
    $includes = $include | ForEach-Object {
        if ($_ -is [string]) { @{ 'local' = $_ } } else { $_ }
    }
    $sastIncluded = $includes | Where-Object { $_.template -eq 'Security/SAST.gitlab-ci.yml' }
    if (-not $sastIncluded) {
        $include += $sastTemplate
    }
    $newYaml['include'] = $include
    $currentYaml.Remove('include')
} else {
    $newYaml['include'] = @($sastTemplate)
}

# 6. variables (SAST)
if ($currentYaml.Contains('variables')) {
    $variables = $currentYaml['variables']
    if (-not $variables) { $variables = [ordered]@{} }
    $currentYaml.Remove('variables')
} else {
    $variables = [ordered]@{}
}

# Добавляем переменные SAST
$variables['SAST_EXCLUDED_PATHS']        = 'spec, test, tests, tmp, enterprise-modules'
$variables['SAST_STAGE']                 = 'sast-checks'
$variables['SAST_SEARCH_MAX_DEPTH']      = '4'
$variables['SAST_ANALYZER_IMAGE_PREFIX'] = '$CI_TEMPLATE_REGISTRY_HOST/security-products'

# Сохраняем их
$newYaml['variables'] = $variables

# 7. Остальные секции
foreach ($key in $currentYaml.Keys) {
    $newYaml[$key] = $currentYaml[$key]
}

# 8. job 'sast'
if (-not $newYaml.Contains('sast')) {
    $newYaml['sast'] = [ordered]@{ 'stage' = 'test' }
}

Write-Host "`n=== Добавление Container Scanning ==="

# Сериализуем => десериализуем, чтобы обновить $tempYaml
$tempContent = ConvertTo-Yaml $newYaml -Options WithIndentedSequences
$tempYaml = ConvertFrom-Yaml $tempContent -Ordered

# Добавляем Jobs/Container-Scanning.gitlab-ci.yml в include
$containerTemplate = @{ 'template' = 'Jobs/Container-Scanning.gitlab-ci.yml' }
if ($tempYaml.Contains('include')) {
    $include2 = $tempYaml['include']
    if ($include2 -isnot [System.Collections.IEnumerable]) { $include2 = @($include2) }
    $includes2 = $include2 | ForEach-Object {
        if ($_ -is [string]) { @{ 'local' = $_ } } else { $_ }
    }
    $containerIncluded = $includes2 | Where-Object { $_.template -eq 'Jobs/Container-Scanning.gitlab-ci.yml' }
    if (-not $containerIncluded) {
        $include2 += $containerTemplate
    }
    $tempYaml['include'] = $include2
} else {
    $tempYaml['include'] = @($containerTemplate)
}

# Переменные container scanning
if ($tempYaml.Contains('variables')) {
    $variables2 = $tempYaml['variables']
} else {
    $variables2 = [ordered]@{}
}

$variables2['CS_IMAGE']            = $csImage.Trim('"').Trim("'")
$variables2['CS_REGISTRY']         = $csRegistry
If($csDockerfile -ne "Dockerfile"){
    $variables2['CS_DOCKERFILE_PATH']  = $csDockerfile
}

$tempYaml['variables'] = $variables2

# Дополним/создадим job container_scanning
if (-not $tempYaml.Contains('container_scanning')) {
    # Если job не существует, создаём
    $tempYaml['container_scanning'] = [ordered]@{
        'stage' = 'test'
        'variables' = @{
            'GIT_STRATEGY' = 'fetch'
        }
    }
} else {
    # Если уже есть, обновим/дополним
    $csJob = $tempYaml['container_scanning']
    if (-not $csJob['stage']) {
        $csJob['stage'] = 'test'
    }
    if (-not $csJob['variables']) {
        $csJob['variables'] = [ordered]@{}
    }
    # добавим GIT_STRATEGY=fetch
    $csJob['variables']['GIT_STRATEGY'] = 'fetch'
    $tempYaml['container_scanning'] = $csJob
}

# Сериализуем обратно
$newContent = ConvertTo-Yaml $tempYaml -Options WithIndentedSequences
$encodedContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($newContent))

# Обновление .gitlab-ci.yml
$updateUrl = "$gitlabUrl/api/v4/projects/$($project.id)/repository/files/$($encodedFilePath)"
$body = @{
    branch         = $project.default_branch
    content        = $encodedContent
    commit_message = "Configure SAST + Container Scanning in .gitlab-ci.yml"
    encoding       = 'base64'
} | ConvertTo-Json -Depth 10

Write-Host "`n=== Обновление .gitlab-ci.yml в репозитории ==="
try {
    Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method Put -Body $body -ContentType 'application/json'
    Write-Host "Файл .gitlab-ci.yml успешно обновлен!"
} catch {
    Write-Host "Ошибка обновления файла: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Создание/обновление переменных CI/CD (CS_REGISTRY_USER, CS_REGISTRY_PASSWORD) ---
Write-Host "`nТеперь можно создать/обновить переменные 'CS_REGISTRY_USER' и 'CS_REGISTRY_PASSWORD' в CI/CD Variables (Project)."
$answer = Read-Host "Создать переменные? (y/n)"
if ($answer -match '^(y|Y)') {
    $registryUser = Read-Host "Введите CS_REGISTRY_USER"
    $registryPass = Read-Host "Введите CS_REGISTRY_PASSWORD" -AsSecureString
    $registryPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($registryPass)
    )

    function Set-GitLabVariable {
        param(
            [string]$ProjectId,
            [string]$VarKey,
            [string]$VarValue,
            [bool]$IsProtected = $false,
            [bool]$IsMasked = $false,
            [string]$EnvScope = "*"
        )

        $varUrl = "$gitlabUrl/api/v4/projects/$ProjectId/variables/$VarKey"
        $bodyVar = @{
            value             = $VarValue
            protected         = $IsProtected
            masked            = $IsMasked
            environment_scope = $EnvScope
        } | ConvertTo-Json

        try {
            # Пробуем PUT (обновление)
            Invoke-RestMethod -Uri $varUrl -Headers $headers -Method PUT -Body $bodyVar -ContentType 'application/json'
            Write-Host "Переменная $VarKey обновлена."
        } catch {
            if ($_.Exception.Message -match '404') {
                # Не существует → POST (создание)
                $postUrl = "$gitlabUrl/api/v4/projects/$ProjectId/variables"
                $bodyPost = @{
                    key               = $VarKey
                    value             = $VarValue
                    protected         = $IsProtected
                    masked            = $IsMasked
                    environment_scope = $EnvScope
                } | ConvertTo-Json

                try {
                    Invoke-RestMethod -Uri $postUrl -Headers $headers -Method Post -Body $bodyPost -ContentType 'application/json'
                    Write-Host "Переменная $VarKey создана."
                } catch {
                    Write-Host "Ошибка при создании переменной ${$VarKey} : $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "Ошибка при обновлении переменной ${$VarKey}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    Set-GitLabVariable -ProjectId $project.id -VarKey "CS_REGISTRY_USER" -VarValue $registryUser -IsProtected:$false -IsMasked:$false
    Set-GitLabVariable -ProjectId $project.id -VarKey "CS_REGISTRY_PASSWORD" -VarValue $registryPassPlain -IsProtected:$false -IsMasked:$true
}

Write-Host "`n=== Скрипт завершен ==="
