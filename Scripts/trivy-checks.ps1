# Get-TrivyAndScan.ps1

# --- 1. Настраиваем пути и URL
$TrivyVersion = "0.58.2"
$TrivyZipURL  = "https://github.com/aquasecurity/trivy/releases/download/v$TrivyVersion/trivy_${TrivyVersion}_windows-64bit.zip"

# Папка для скачивания и распаковки. Вы можете поменять на свой путь.
$DownloadDir = "C:\temp\Trivy"
$ZipFilePath = Join-Path $DownloadDir "trivy_${TrivyVersion}_windows-64bit.zip"
$ExtractPath = Join-Path $DownloadDir "trivy_${TrivyVersion}_windows-64bit"

# --- 2. Создаём папку, скачиваем и распаковываем ---
Write-Host "Создаём папку: $DownloadDir"
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

Write-Host "Скачиваем Trivy $TrivyVersion для Windows (x64)..."
Invoke-WebRequest -Uri $TrivyZipURL -OutFile $ZipFilePath

Write-Host "Распаковываем zip-архив..."
Expand-Archive -Path $ZipFilePath -DestinationPath $ExtractPath -Force

# После распаковки в $ExtractPath появятся файлы, среди которых trivy.exe
$TrivyExe = Join-Path $ExtractPath "trivy.exe"
if (Test-Path $TrivyExe) {
    Write-Host "Trivy успешно распакован: $TrivyExe"
} else {
    Write-Host "Не найден trivy.exe в $ExtractPath. Проверьте содержимое архива."
    exit 1
}

# --- 3. Запрашиваем у пользователя контекст, namespace и формат отчёта ---
$k8sContext = Read-Host "Введите Kubernetes context (напр. minikube)"
$namespace  = Read-Host "Введите namespace для сканирования (пусто, чтобы все)"
$report     = Read-Host "Введите формат отчёта (all, summary):"

if (-not $report) {
    $report = "summary"
    Write-Host "Отчёт не указан, используем по умолчанию: $report"
}

# --- 4. Формируем аргументы для Trivy ---
# Базовая команда: trivy k8s --report summary <context>
# Если указан namespace, добавляем "--include-namespaces <namespace>"

$arguments = @("k8s")

# Указываем флаг --report
$arguments += "--report"
$arguments += $report

# Если пользователь ввёл namespace, добавим
if ($namespace) {
    $arguments += "--include-namespaces"
    $arguments += $namespace
}

# В конце добавляем сам context
if ($k8sContext) {
    $arguments += $k8sContext
} else {
    Write-Host "Контекст не указан, Trivy будет использовать текущий контекст по умолчанию."
}

Write-Host "`nКоманда, которая будет выполнена:"
Write-Host "`"$TrivyExe $($arguments -join ' ')`""

# --- 5. Запускаем сканирование ---
Write-Host "`nЗапуск сканирования..."
& $TrivyExe $arguments

Write-Host "`nГотово. Для просмотра подробностей выше прокрутите вывод."
