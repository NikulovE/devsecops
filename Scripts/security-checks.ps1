<#
    Скрипт: TrivyGitLabPipelineScan.ps1

    1) Скачивает и распаковывает Trivy (Windows x64).
    2) Спрашивает GitLab URL, token, путь к проекту.
    3) Находит последний pipeline по default_branch → его jobs.
    4) Скачивает логи build-job, парсит строки "Successfully tagged <image>".
    5) Если нашли несколько образов — предлагаем выбор. Если один — сразу спрашиваем (y/n). Если ноль — пропускаем.
    6) Если "Yes", делаем `trivy image`.
    7) (Опционально) спрашиваем context/namespace → делаем `trivy k8s`.
#>

# -----------------------------
# 0. Параметры для скачивания Trivy
# -----------------------------
$TrivyVersion = "0.58.2"
$TrivyZipURL  = "https://github.com/aquasecurity/trivy/releases/download/v$TrivyVersion/trivy_${TrivyVersion}_windows-64bit.zip"

$DownloadDir = "C:\temp\Trivy"
$ZipFilePath = Join-Path $DownloadDir "trivy_${TrivyVersion}_windows-64bit.zip"
$ExtractPath = Join-Path $DownloadDir "trivy_${TrivyVersion}_windows-64bit"

# -----------------------------
# 1. Скачивание и распаковка Trivy
# -----------------------------
Write-Host "=== Установка Trivy v$TrivyVersion ==="
if (!(Test-Path $DownloadDir)) {
    New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
}
Write-Host "Скачиваю: $TrivyZipURL"
Invoke-WebRequest -Uri $TrivyZipURL -OutFile $ZipFilePath

Write-Host "Распаковка в $ExtractPath"
Expand-Archive -Path $ZipFilePath -DestinationPath $ExtractPath -Force

$TrivyExe = Join-Path $ExtractPath "trivy.exe"
if (!(Test-Path $TrivyExe)) {
    Write-Host "Ошибка: trivy.exe не найден" -ForegroundColor Red
    return
}
Write-Host "Trivy скачан и распакован: $TrivyExe"

# -----------------------------
# 2. Ввод данных GitLab + Project + Token
# -----------------------------
$gitlabUrlDefault = "https://mygitlab.tehlab.org:9443"
$gitlabUrl = Read-Host "GitLab URL (по умолчанию: $gitlabUrlDefault)"
if ([string]::IsNullOrWhiteSpace($gitlabUrl)) {
    $gitlabUrl = $gitlabUrlDefault
}
Write-Host "GitLab URL = $gitlabUrl"

$projectPath = Read-Host "Введите путь к проекту (например, mygroup/myproject)"
if ([string]::IsNullOrWhiteSpace($projectPath)) {
    Write-Host "Нет пути к проекту. Завершаем."
    return
}
$encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)

$secureToken = Read-Host "Введите ваш PAT (Personal Access Token)" -AsSecureString
if (!$secureToken) {
    Write-Host "Нет токена. Завершаем."
    return
}
$tokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
)

$headers = @{ 'Authorization' = "Bearer $tokenPlain" }

# -----------------------------
# 3. Получаем project info, узнаём default_branch
# -----------------------------
$projectApiUrl = "$gitlabUrl/api/v4/projects/$encodedProjectPath"
try {
    $project = Invoke-RestMethod -Uri $projectApiUrl -Headers $headers -Method Get
    Write-Host "Проект: $($project.name), ID=$($project.id)"
    Write-Host "default_branch = $($project.default_branch)"
} catch {
    Write-Host "Ошибка получения информации о проекте: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$defaultBranch = $project.default_branch
if (-not $defaultBranch) {
    Write-Host "Не найден default_branch!" -ForegroundColor Yellow
    return
}

# -----------------------------
# 4. Получаем последний pipeline на этой ветке
# -----------------------------
Write-Host "`n=== Поиск последнего Pipeline ==="
$pipelineUrl = "$gitlabUrl/api/v4/projects/$($project.id)/pipelines?ref=$defaultBranch&per_page=1"
try {
    $pipelines = Invoke-RestMethod -Uri $pipelineUrl -Headers $headers -Method Get
    if ($pipelines.Count -gt 0) {
        $lastPipeline = $pipelines[0]
        Write-Host "Найден pipeline ID=$($lastPipeline.id), status=$($lastPipeline.status), created_at=$($lastPipeline.created_at)"
    } else {
        Write-Host "Нет pipeline на ветке $defaultBranch"
        return
    }
} catch {
    Write-Host "Ошибка при получении pipeline: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# -----------------------------
# 5. Получаем jobs из этого pipeline
# -----------------------------
Write-Host "`n=== Получаем jobs из pipeline ID=$($lastPipeline.id) ==="
$jobsUrl = "$gitlabUrl/api/v4/projects/$($project.id)/pipelines/$($lastPipeline.id)/jobs"
try {
    $jobs = Invoke-RestMethod -Uri $jobsUrl -Headers $headers -Method Get
    if ($jobs.Count -eq 0) {
        Write-Host "Нет jobs в pipeline"
        return
    }
} catch {
    Write-Host "Ошибка при получении jobs: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host "Список jobs:"
foreach ($j in $jobs) {
    Write-Host "- Job $($j.id): name=$($j.name), status=$($j.status), stage=$($j.stage)"
}

# Допустим, ищем job со stage='build' или именем, содержащим 'build'
$buildJob = $jobs | Where-Object { $_.stage -eq "build" -or $_.name -like "*build*" } | Sort-Object id -Descending | Select-Object -First 1
if (-not $buildJob) {
    Write-Host "`nНе найден job с stage=build или именем '*build*'. Пропускаем поиск образов."
} else {
    Write-Host "`nНайден build-job: id=$($buildJob.id), name=$($buildJob.name)."

    # -----------------------------
    # 6. Скачиваем лог job-а и ищем строки "Successfully tagged <image>"
    # -----------------------------
    $jobLogUrl = "$gitlabUrl/api/v4/projects/$($project.id)/jobs/$($buildJob.id)/trace"
    $buildLog   = Invoke-RestMethod -Uri $jobLogUrl -Headers $headers -Method Get
    if ($buildLog) {
        # Найдём все строки вида: Successfully tagged registry.tehlab.org:5000/...
        $tagRegex = "Successfully tagged\s+([^`r`n]+)"
        $matches = [System.Text.RegularExpressions.Regex]::Matches($buildLog, $tagRegex)

        $foundImages = @()
        foreach ($m in $matches) {
            $foundImages += $m.Groups[1].Value.Trim()
        }

        if ($foundImages.Count -eq 0) {
            Write-Host "Не найдено строк 'Successfully tagged ...'"
        } elseif ($foundImages.Count -eq 1) {
            # Если ровно один образ найден
            $singleImage = $foundImages[0]
            Write-Host "Найден единственный образ: $singleImage"
            $answer = Read-Host "Запустить trivy image $singleImage ? (y/n)"
            if ($answer -match '^(y|Y)') {
                & $TrivyExe image $singleImage
            }
        } else {
            # Несколько образов, предлагаем выбрать
            Write-Host "`nНайдено несколько образов:"
            for ($i=0; $i -lt $foundImages.Count; $i++) {
                Write-Host "[$i] $($foundImages[$i])"
            }
            $choice = Read-Host "Введите индекс образа для сканирования"
            if ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $foundImages.Count) {
                $selectedImage = $foundImages[[int]$choice]
                Write-Host "Выбрали: $selectedImage"
                & $TrivyExe image $selectedImage
            } else {
                Write-Host "Некорректный ввод, пропускаем сканирование."
            }
        }
    }
}

# -----------------------------
# 7. (Опционально) Сканирование Kubernetes (если нужно)
# -----------------------------
Write-Host "`nСканировать Kubernetes кластер? (по умолч. нет)"
$context = Read-Host "Введите K8s context (пусто => пропустить)"
if ($context) {
    $namespace = Read-Host "Введите namespace (пусто => все)"
    Write-Host "`nБудем сканировать context=$context, namespace=$namespace"

    $args = @("k8s", "--report", "summary")
    if ($namespace) {
        $args += "--include-namespaces"
        $args += $namespace
    }
    $args += $context

    & $TrivyExe $args
}

# -----------------------------
# 8. (Опционально) kube-bench
# -----------------------------
Write-Host "`nЗапустить kube-bench (CIS Kubernetes Benchmark)? (y/n)"
$kubeBenchAnswer = Read-Host
if ($kubeBenchAnswer -match '^(y|Y)') {
    # Предположим, у нас уже настроен kubectl, тот же context/namespace.

    # 8.1. Скачиваем job.yaml
    $kubeBenchJobUrl = "https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml"
    $jobFile = "kube-bench-job.yaml"
    Write-Host "Скачиваем kube-bench Job YAML: $kubeBenchJobUrl"
    Invoke-WebRequest -Uri $kubeBenchJobUrl -OutFile $jobFile

    # 8.2. Применяем (kubectl apply -f job.yaml)
    Write-Host "Применяем kube-bench Job..."
    kubectl apply -f $jobFile

    # 8.3. Ждём, пока под завершится
    # Можно просто смотреть, пока не появится Completed
    Write-Host "Ожидаем выполнения Job kube-bench..."
    do {
        Start-Sleep -Seconds 3
        $pods = kubectl get pods -l job-name=kube-bench --no-headers
        # Пример: "kube-bench-xyz 0/1 Completed 0 30s"
        $done = $false
        foreach ($line in $pods) {
            if ($line -match 'Completed') {
                $done = $true
                break
            }
        }
    } while (-not $done)

    # 8.4. Берём имя pod и выводим логи
    $podName = (kubectl get pods -l job-name=kube-bench -o name)
    Write-Host "`nРезультаты kube-bench:"
    kubectl logs $podName
}

Write-Host "`n=== Готово. ==="


Write-Host "`n=== Готово. ==="
