# WinClean

A safety-first Windows cleanup module for PowerShell. WinClean removes temp files, caches and stale build output, and frees the RAM standby list. Anything it can't prove is safe to delete, it leaves alone.

```powershell
Import-Module .\WinClean\WinClean.psd1
Invoke-WinClean -DryRun          # see what would be removed - deletes nothing
Invoke-WinClean -Quarantine      # move files aside instead of deleting them
```

- **Dry-run first.** Every destructive action can be previewed with `-DryRun`.
- **Allowlist only.** Every cleanup target is an explicit entry. Nothing is matched by wildcard.
- **One central safety gate.** Every folder passes `Test-PathSafety` before anything inside it is touched.
- **Never follows junctions or symlinks**, so a link can't redirect a cleanup into your data.
- **Fails safe.** A locked, ambiguous or unreadable file is skipped, not forced.
- **Reversible when you want it.** `-Quarantine` moves files aside for 7 days instead of deleting them.

---

## Contents

- [What it never touches](#what-it-never-touches)
- [What it cleans](#what-it-cleans)
- [Requirements and installation](#requirements-and-installation)
- [Usage](#usage)
- [How the safety model works](#how-the-safety-model-works)
- [Configuration file](#configuration-file)
- [Run log](#run-log)
- [Deliberately not included](#deliberately-not-included)
- [Development](#development)

---

## What it never touches

| Never deleted or modified | How it is enforced |
|---|---|
| Desktop, Documents, Downloads, Pictures, Music, Videos, Favorites, OneDrive (including redirected locations) | Protected in `Test-PathSafety`, together with everything below them |
| Recycle Bin, System Restore points (`System Volume Information`), Recovery, Boot/EFI | Protected on **every** drive |
| `C:\Windows` (Prefetch, WinSxS, System32, event logs, registry hives, Installer...) | Protected, except `Windows\Temp` and `SoftwareDistribution\Download` |
| Program Files, your user profile, the AppData roots, ProgramData | Protected. These folders and anything that contains them can never be a target |
| Browser cookies, passwords, history, bookmarks, extensions | Browser profile folders are protected; only their `Cache`, `Code Cache`, `GPUCache` (and Firefox `cache2`) folders may be cleaned |
| The registry | Only read (startup report); never written |

Projects stored on Desktop, Documents or Downloads are protected too. Build-output cleanup and `git gc` skip them, and the output says why.

## What it cleans

**Default targets** (from [`Config/winclean.config.json`](WinClean/Config/winclean.config.json)):

| Target | Files kept |
|---|---|
| User temp (`%TEMP%`), Windows temp | newer than `-MinAgeHours` (default 1 h), so running installers aren't disturbed |
| Internet cache, DirectX shader cache | none |
| App crash dumps, Windows Error Reporting queue and archive | none |
| Browser caches: Chrome, Edge, Brave (all profiles), Firefox | none |
| Windows Update download cache | skipped while Windows Update is installing; services are stopped and restored |

The run also flushes the DNS cache and the RAM cache (working sets, modified page list, standby list). The modified list is written to disk first, so nothing is lost.

**Opt-in developer cleanup** (`-IncludeDev`). Anything written in the last 7 days (`-DevAgeHours`) is kept:

| Target | Rule |
|---|---|
| npm cache | cleaned only after `npm cache verify` succeeds, then verified again |
| pip cache, cargo registry downloads, NuGet HTTP cache, vcpkg archives/downloads | tool cache overrides (`PIP_CACHE_DIR`, `CARGO_HOME`, ...) are honoured |
| VS Code caches | `Cache`, `CachedData`, `CachedExtensionVSIXs`, `Code Cache`, `GPUCache` |
| VS Code workspace storage | only for workspaces whose folder **provably no longer exists**; remote, network and unplugged-drive workspaces are kept |
| Build output under `-DevRoot` | see [build artifacts](#build-artifacts) |
| `git gc` (`-GitGc`) | plain `git gc` only; repos with a git operation in progress are skipped |
| Docker (`-ConfirmDockerPrune`) | `docker image prune --force`: dangling images only, never `--all` |
| WSL 2 memory | reported with reclaim steps; WinClean never runs `wsl --shutdown` |

## Requirements and installation

- Windows 10 or 11
- Windows PowerShell 5.1 (built in). PowerShell 7 is declared in the manifest but is still experimental (see CI).
- Administrator rights are optional. Without them a real run skips Windows temp, error reports, the Update cache and the RAM flush, instead of failing on them. `-DryRun` works without elevation.

```powershell
git clone <this repository>
cd WindowsCleaner
Import-Module .\WinClean\WinClean.psd1
```

For a classic double-click-style run, use the bundled launcher. It asks for elevation, runs the cleanup and waits for Enter:

```powershell
.\Clean-Windows.ps1 -DryRun
```

## Usage

### Clean up

```powershell
Invoke-WinClean -DryRun                          # preview, deletes nothing
Invoke-WinClean                                  # clean
Invoke-WinClean -SkipBrowsers -MinAgeHours 6     # keep browser caches and today's temp files
Invoke-WinClean -Quarantine                      # move files to quarantine instead of deleting
$run = Invoke-WinClean -DryRun -PassThru         # get a result object
$run.Targets | Sort-Object Bytes -Descending | Format-Table Label, Status, Files, Bytes
```

| Parameter | Purpose |
|---|---|
| `-DryRun` | Report what would be removed; change nothing |
| `-MinAgeHours` | Keep temp files newer than this (default `1`) |
| `-SkipBrowsers`, `-SkipUpdateCache`, `-SkipRam` | Leave that area alone |
| `-ConfigPath` | Extend or override the default targets with your own [config file](#configuration-file) |
| `-Quarantine` | Move files to `%TEMP%\WinClean-Quarantine\<yyyyMMdd-HHmmss>\` instead of deleting them |
| `-QuarantineDays` | Purge quarantine runs older than this many days (default `7`) |
| `-IncludeDev`, `-DevRoot`, `-DevAgeHours` | Developer cleanup (see above) |
| `-GitGc`, `-ConfirmDockerPrune` | Opt-in git and Docker maintenance |
| `-NoLog` | Don't record this run in the [run log](#run-log) |
| `-PassThru` | Return a `WinClean.RunResult` object |

### Quarantine

```powershell
Invoke-WinClean -Quarantine
```

Files are moved, keeping their original path inside the run folder (`C:\a\b.tmp` becomes `<run>\C\a\b.tmp`), so anything can be moved back by hand. Every run (normal runs included) first purges quarantine runs older than `-QuarantineDays`. Quarantined files still take disk space until they're purged; the summary reports them separately from freed space. Docker prune is skipped under `-Quarantine`, because images can't be quarantined.

### Developer cleanup

```powershell
Invoke-WinClean -DryRun -IncludeDev -DevRoot C:\src
Invoke-WinClean -IncludeDev -DevRoot C:\src, D:\work -GitGc -ConfirmDockerPrune
```

#### Build artifacts

A folder is cleaned only when **both** of these hold: it sits next to its ecosystem's project file, **and** its contents prove it is tool output. A folder that is merely *named* `bin` or `build` is never enough.

| Ecosystem | Folder | Next to | Proof inside |
|---|---|---|---|
| .NET | `bin`, `obj` | `*.csproj`, `*.fsproj`, `*.vbproj` | `Debug`/`Release` or `project.assets.json` |
| CMake | `build` / `CMakeFiles` | `CMakeLists.txt` | `CMakeCache.txt` / `cmake.check_cache` |
| Cargo | `target` | `Cargo.toml` | Cargo's `CACHEDIR.TAG` signature |
| Node | `build` | `package.json` | must be git-ignored (there's no structural proof) |

Folders that hold any git-tracked file are refused. If anything in an artifact folder was written within `-DevAgeHours`, the whole folder is left alone, so a build is never left half-deleted.

### Analyse without deleting

`Get-WinCleanReport` is read-only. It reports the largest folders, memory per application and startup programs.

```powershell
Get-WinCleanReport                                        # readable table
Get-WinCleanReport -ScanRoot C:\src, D:\ -Top 20 -MaxDepth 4
Get-WinCleanReport -OutputFormat json | Set-Content report.json
Get-WinCleanReport -OutputFormat csv  | Set-Content report.csv
(Get-WinCleanReport -Section Startup -OutputFormat object).Startup | Where-Object Enabled
```

Folder sizes skip junctions and OneDrive online-only files, so nothing is counted twice and files that aren't on disk don't inflate totals. Startup entries show Task Manager's enabled/disabled state and whether the program is running now. Their *impact* column is an **estimate** from current memory and CPU use, because Task Manager's own figure comes from boot traces that scripts can't read.

### Schedule a weekly run

```powershell
Register-WinCleanSchedule -WhatIf                                          # preview
Register-WinCleanSchedule -CleanParameters @{ Quarantine = $true }         # Sundays 03:00
Register-WinCleanSchedule -DayOfWeek Saturday -At 21:00 -CleanParameters @{ IncludeDev = $true; DevRoot = 'C:\src' } -Force
Register-WinCleanSchedule -Elevated -Force                                 # full clean; needs an elevated session
Unregister-WinCleanSchedule
```

- **Where and how it runs:** the task lives in its own `\WinClean\` Task Scheduler folder and runs as you while you're logged on, so no password is stored. If the computer was off at the scheduled time, it runs at the next opportunity.
- **Readable:** the exact command is shown as plain text under the task's *Actions*.
- **Checked at registration:** `-CleanParameters` keys are validated against `Invoke-WinClean`'s real parameters, so a typo fails immediately instead of at 3 AM.
- **No accidental changes:** an existing task is only replaced with `-Force`, and both commands support `-WhatIf`.
- **If you move the folder:** the task points at the module's current location. Register again after moving it.

## How the safety model works

Every cleanup folder goes through **`Test-PathSafety`** first. A path is rejected unless it passes every layer:

1. **Unambiguous input.** Only absolute drive paths are accepted. UNC and device paths (`\\server\...`, `\\?\`), relative paths, wildcards, alternate data streams, unexpanded `%VARIABLES%`, reserved device names (`NUL`, `CON`...) and 8.3 short names that can't be resolved are all rejected.
2. **Normalization before comparison.** Forward slashes, `..`, duplicate separators, and the trailing dots and spaces Windows silently strips are all resolved first. That way `C:\Users\me\Documents.` or `%TEMP%\..\..\..\Documents` can't slip past the blocklist.
3. **No drive roots, minimum depth 2.**
4. **Protected locations.** The folders in [What it never touches](#what-it-never-touches), with three kinds of rules:
   - *containers* (user profile, AppData roots, ...) can never be a target, nor be inside one;
   - *subtrees* (Windows, Program Files, personal folders, browser profiles) are closed except for listed exceptions;
   - *patterns* (Recycle Bin, System Volume Information, ...) apply on every drive.
5. **No junctions or symlinks anywhere on the path.**

While a folder is being emptied:
- **Links:** junctions and symlinks inside it are skipped, never followed.
- **Locked files:** files in use are skipped.
- **Folders:** emptied sub-folders are removed with a non-recursive delete, which can't remove anything that still has contents.
- **Off-limits folders:** WinClean never descends into its own module folder or into the quarantine.

The test suite covers each of these rules, with real junctions, git repositories and 8.3 paths.

## Configuration file

The default targets live in [`WinClean/Config/winclean.config.json`](WinClean/Config/winclean.config.json). To change them, write your own file. [`my-targets.example.json`](WinClean/Config/my-targets.example.json) is a starting point.

```json
{
  "version": 1,
  "extendDefaults": true,
  "targets": [
    { "label": "User temp", "path": "%TEMP%", "ageHours": 24, "category": "temp" },
    { "label": "Internet cache", "path": "%LOCALAPPDATA%\\Microsoft\\Windows\\INetCache", "ageHours": 0, "category": "cache", "enabled": false },
    { "label": "Gradle build cache", "path": "%USERPROFILE%\\.gradle\\caches\\build-cache-1", "ageHours": 168, "category": "cache" }
  ]
}
```

```powershell
Invoke-WinClean -DryRun -ConfigPath .\my-targets.json
```

| Field | Meaning |
|---|---|
| `label` | Display name, unique per file. An entry with the same label as a default replaces it. |
| `path` | Folder to empty. `%VAR%`, `$env:VAR` and `${env:VAR}` are expanded; an undefined variable skips the target instead of expanding to nothing. |
| `category` | Lowercase tag such as `temp`, `cache`, `crash` |
| `ageHours` | Keep files newer than this; `null` means use `-MinAgeHours` |
| `requiresAdmin` | Skip on non-elevated real runs (default `false`) |
| `enabled` | `false` ignores the entry (default `true`) |
| `extendDefaults` | Top level: `false` replaces the default list instead of extending it |

Every entry still passes `Test-PathSafety`, so a config pointing at `Documents` is refused. A broken config file stops the run before anything is deleted; a single invalid entry is skipped and reported.

## Run log

Every run, dry runs included, is appended to `%LOCALAPPDATA%\WinClean\run-log.json`. The log stays on your machine; nothing is ever sent anywhere.

```json
[
  {
    "timestamp": "2026-10-04T03:00:01.1234567+03:00",
    "bytesFreed": 1717986918,
    "filesRemoved": 12180,
    "dryRun": false,
    "quarantine": false,
    "bytesQuarantined": 0,
    "filesQuarantined": 0,
    "skippedTargets": 0,
    "isAdmin": true,
    "durationSeconds": 41.7,
    "moduleVersion": "0.1.0"
  }
]
```

```powershell
Get-Content "$env:LOCALAPPDATA\WinClean\run-log.json" -Raw | ConvertFrom-Json | Format-Table timestamp, bytesFreed, filesRemoved, dryRun
```

The log keeps the newest 500 runs. Concurrent runs can't lose each other's entries, and an unreadable log is set aside rather than overwritten. A logging problem never fails a cleanup. Use `-NoLog` to skip it.

## Deliberately not included

| Left out | Why |
|---|---|
| Restore-point creation | Restore points capture system files and the registry, not temp or cache data, and WinClean makes no lasting system changes for one to roll back. `-Quarantine` is the recovery path for removed files. |
| `~/.nuget/packages`, cargo `registry/src`, vcpkg `buildtrees` | Age-based deletion can leave half-extracted packages that look installed but are missing files, which breaks builds |
| `node_modules` | Reinstalling costs more than the space is usually worth |
| `wsl --shutdown`, `docker image prune --all` | They would stop running distros or remove images you still use |
| Docker's virtual disk (`AppData\Local\Docker`) | Often the largest folder on a developer machine, but it isn't a cache; `Get-WinCleanReport` shows its size |

## Development

```powershell
.\Invoke-Tests.ps1                     # runs the full Pester 5 suite
.\Invoke-Tests.ps1 -Output Normal -TestResultPath testResults.xml
```

`Invoke-Tests.ps1` uses an installed Pester 5 if there is one. Otherwise it saves Pester into `.tools\Modules` inside the repo, so nothing is installed system-wide (this also works with Controlled Folder Access on). The tests only modify files inside Pester's temporary `TestDrive`; they never change your real temp folder, quarantine, run log or Task Scheduler.

**CI:** [`.github/workflows/tests.yml`](.github/workflows/tests.yml) runs the suite on `windows-latest` for every push and pull request. Windows PowerShell 5.1 is required; PowerShell 7 runs as an experimental job.

```
WindowsCleaner/
├── Clean-Windows.ps1           self-elevating launcher (original script interface)
├── Invoke-Tests.ps1            test runner (bootstraps Pester 5)
└── WinClean/
    ├── WinClean.psd1 / .psm1   module manifest and loader
    ├── Public/                 Invoke-WinClean, Get-WinCleanReport,
    │                           Register-WinCleanSchedule, Unregister-WinCleanSchedule
    ├── Private/                Test-PathSafety, Clear-FolderContents, quarantine,
    │                           developer cleanup, report collectors, run log ...
    ├── Config/                 default targets and an example user config
    └── Tests/                  Pester 5 suites
```
