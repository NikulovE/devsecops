# --- Запрос параметров у пользователя ---
Write-Host "Введите GitLab URL (по умолчанию: https://mygitlab.tehlab.org:9443):"
$gitlabUrl = Read-Host
if ([string]::IsNullOrWhiteSpace($gitlabUrl)) {
    $gitlabUrl = "https://mygitlab.tehlab.org:9443"
}
Write-Host "GitLab URL = $gitlabUrl"

# Запрос Personal Access Token (PAT)
$secureToken = Read-Host "Введите ваш Personal Access Token (PAT)" -AsSecureString
if (-not $secureToken) {
    Write-Host "Токен не задан. Завершаем." -ForegroundColor Yellow
    exit
}
$accessToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
)

# Запрос пути к проекту
Write-Host "Введите путь к проекту (например, mygroup/devsecops):"
$projectPath = Read-Host
if ([string]::IsNullOrWhiteSpace($projectPath)) {
    Write-Host "Путь к проекту не указан. Завершаем." -ForegroundColor Yellow
    exit
}
$encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)
Write-Host "Encoded project path: $encodedProjectPath"

# Заголовки для аутентификации
$headers = @{
    'Authorization' = "Bearer $accessToken"
}

# Получаем информацию о проекте для получения projectId и default_branch
$apiUrl = "$gitlabUrl/api/v4/projects/$encodedProjectPath"
try {
    $project = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
    Write-Host "`nИнформация о проекте:"
    $project | Format-List
} catch {
    Write-Host "Ошибка при получении проекта: $($_.Exception.Message)" -ForegroundColor Red
    exit
}

# Теперь используем динамически полученный project.id
$projectId = $project.id
$defaultBranch = $project.default_branch
if (-not $projectId -or -not $defaultBranch) {
    Write-Host "Не удалось получить project ID или default_branch. Завершаем." -ForegroundColor Yellow
    exit
}

# URL для получения последнего конвейера, используя projectId и default_branch
$apiUrlPipeline = "$gitlabUrl/api/v4/projects/$projectId/pipelines?ref=$defaultBranch&per_page=1&order_by=id&sort=desc"

# Получение последнего pipeline
$responsePipeline = Invoke-RestMethod -Uri $apiUrlPipeline -Headers $headers -Method Get
if ($responsePipeline.Count -eq 0) {
    Write-Host "Не удалось получить последний конвейер для проекта. Проверьте параметры и доступы."
    exit
}
$pipelineId = $responsePipeline[0].id

# Получение jobs для последнего pipeline
$jobsUrl = "$gitlabUrl/api/v4/projects/$projectId/pipelines/$pipelineId/jobs"
$responseJobs = Invoke-RestMethod -Uri $jobsUrl -Method Get -Headers $headers


# Типы артефактов для загрузки
$artifactTypes = @('sast', 'container_scanning', 'dependency_scanning', 'dast') # Добавьте нужные типы

# Создаем папку для сохранения артефактов
$outputDir = "./artifacts"
if (!(Test-Path -Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

# Шаг 1: Получение страницы входа и извлечение authenticity_token
$response = Invoke-RestMethod -Uri "$gitlabUrl/users/sign_in" -Method Get -SessionVariable session -UseBasicParsing
$csrfTokenMatch = [regex]::Match($response, 'name="authenticity_token" value="([^"]+)"')

if ($csrfTokenMatch.Success) {
    $csrfToken = $csrfTokenMatch.Groups[1].Value
} else {
    Write-Host "Ошибка: Не удалось извлечь authenticity_token."
    exit
}

$gitlabUser = "root"
$gitlabPassword = "ytHWgUbq9vZDUm8F/ciOu62iCwx4Znwuuh0xNxCTRwM="

# Шаг 2: Вход с использованием username и password
$loginResponse = Invoke-RestMethod -Uri "$gitlabUrl/users/sign_in" -Method Post -WebSession $session -UseBasicParsing -Body @{
    "authenticity_token" = $csrfToken
    "user[login]"         = $gitlabUser
    "user[password]"      = $gitlabPassword
    "user[remember_me]"   = "0"
}

if ($session.Cookies.Count -eq 0) {
    Write-Host "Ошибка: Не удалось войти в систему. Проверьте учетные данные."
    exit
}

# Скачивание артефактов
foreach ($artifactType in $artifactTypes) {
    Write-Host "Ищем задания с артефактами типа '$artifactType'..."

    $jobsWithArtifacts = $responseJobs | Where-Object { $_.name -match $artifactType }

    if (-not $jobsWithArtifacts) {
        Write-Host "Не найдено заданий с артефактами типа '$artifactType'."
        continue
    }

    foreach ($job in $jobsWithArtifacts) {
        $jobId = $job.id
        $artifactUrl = "$gitlabUrl/$projectPath/-/jobs/$jobId/artifacts/download?file_type=$artifactType"
        $outputPath = "$outputDir/${artifactType}_artifact_job_$jobId.json"

        Write-Host "Скачивание артефакта из job $jobId (тип: $artifactType)..."

        try {
            Invoke-WebRequest -Uri $artifactUrl -WebSession $session -UseBasicParsing -OutFile $outputPath
            Write-Host "Артефакт успешно скачан и сохранен как $outputPath"
        } catch {
            Write-Host "Ошибка при скачивании артефакта из job $jobId : $($_.Exception.Message)"
        }
    }
}
