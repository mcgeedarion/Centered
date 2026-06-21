[CmdletBinding()]
param(
    [string]$Python = "",
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$VenvDir = Join-Path $ProjectDir ".venv-build"
$BuildDir = Join-Path $ProjectDir "build"
$DistDir = Join-Path $ProjectDir "dist"
$ExePath = Join-Path $DistDir "CenteredWin.exe"

function Invoke-Checked {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$FilePath $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Resolve-PythonCommand {
    if ($Python) {
        return @($Python)
    }

    $candidates = @(
        @("py", "-3.10"),
        @("py", "-3"),
        @("python")
    )

    foreach ($candidate in $candidates) {
        $file = $candidate[0]
        $args = @()
        if ($candidate.Count -gt 1) {
            $args = @($candidate[1..($candidate.Count - 1)])
        }

        try {
            & $file @args -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" *> $null
            if ($LASTEXITCODE -eq 0) {
                return $candidate
            }
        } catch {
        }
    }

    throw "Python 3.10 or newer was not found. Install Python from https://www.python.org/downloads/windows/ and rerun this script."
}

Push-Location $ProjectDir
try {
    if ($Clean) {
        foreach ($path in @($BuildDir, $DistDir)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }

    $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        $pythonCommand = @(Resolve-PythonCommand)
        $pythonFile = $pythonCommand[0]
        $pythonArgs = @()
        if ($pythonCommand.Count -gt 1) {
            $pythonArgs = @($pythonCommand[1..($pythonCommand.Count - 1)])
        }

        Write-Host "Creating build virtual environment..."
        Invoke-Checked $pythonFile ($pythonArgs + @("-m", "venv", $VenvDir))
    }

    Write-Host "Installing build dependencies..."
    Invoke-Checked $VenvPython @("-m", "pip", "install", "--upgrade", "pip")
    Invoke-Checked $VenvPython @("-m", "pip", "install", "-r", (Join-Path $ProjectDir "requirements-build.txt"))

    Write-Host "Building CenteredWin.exe..."
    Invoke-Checked $VenvPython @(
        "-m", "PyInstaller",
        "--noconfirm",
        "--clean",
        "--noconsole",
        "--onefile",
        "--name", "CenteredWin",
        "--distpath", $DistDir,
        "--workpath", (Join-Path $BuildDir "pyinstaller"),
        "--specpath", $BuildDir,
        (Join-Path $ProjectDir "main.py")
    )

    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "Expected build output was not created: $ExePath"
    }

    Write-Host "Build complete: $ExePath"
} finally {
    Pop-Location
}
