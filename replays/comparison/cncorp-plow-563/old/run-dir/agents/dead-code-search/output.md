## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `InstallerView.init(downloadManager:client:keepMacAwake:onDismiss:)` at `app/Phoenix/InstallerView.swift:4` (modified)
Old shape: `InstallerView(downloadManager: RuntimeDownloadManager, client: DaemonClient, onDismiss: () -> Void)`
New shape: `InstallerView(downloadManager: RuntimeDownloadManager, client: DaemonClient, keepMacAwake: KeepMacAwake, onDismiss: () -> Void)`
Callers found:
- `app/Phoenix/PhoenixApp.swift:150` — matches new shape
Verdict: clean

### `SettingsView.init(client:downloadManager:keepMacAwake:onDismiss:)` at `app/Phoenix/SettingsView.swift:3` (modified)
Old shape: `SettingsView(client: DaemonClient, downloadManager: RuntimeDownloadManager, onDismiss: () -> Void)`
New shape: `SettingsView(client: DaemonClient, downloadManager: RuntimeDownloadManager, keepMacAwake: KeepMacAwake, onDismiss: () -> Void)`
Callers found:
- `app/Phoenix/InstallerView.swift:55` — matches new shape
Verdict: clean

### `StatusView.init(client:downloadManager:appUpdater:installerController:audioRecorder:keepMacAwake:)` at `app/Phoenix/StatusView.swift:171` (modified)
Old shape: `StatusView(client: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder)`
New shape: `StatusView(client: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, keepMacAwake: KeepMacAwake)`
Callers found:
- `app/Phoenix/MenuBarController.swift:38` — matches new shape
Verdict: clean

### `MenuBarController.init(daemonClient:downloadManager:appUpdater:installerController:audioRecorder:keepMacAwake:isDev:)` at `app/Phoenix/MenuBarController.swift:27` (modified)
Old shape: `init(daemonClient: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, isDev: Bool)`
New shape: `init(daemonClient: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, keepMacAwake: KeepMacAwake, isDev: Bool)`
Callers found:
- `app/Phoenix/PhoenixApp.swift:88` — matches new shape
Verdict: clean

### `InstallerWindowController.show(downloadManager:client:keepMacAwake:)` at `app/Phoenix/PhoenixApp.swift:140` (modified)
Old shape: `show(downloadManager: RuntimeDownloadManager, client: DaemonClient)`
New shape: `show(downloadManager: RuntimeDownloadManager, client: DaemonClient, keepMacAwake: KeepMacAwake)`
Callers found:
- `app/Phoenix/PhoenixApp.swift:101` — matches new shape
- `app/Phoenix/PhoenixApp.swift:115` — matches new shape
- `app/Phoenix/PhoenixApp.swift:125` — matches new shape
- `app/Phoenix/StatusView.swift:258` — matches new shape
- `app/Phoenix/StatusView.swift:264` — matches new shape
- `app/Phoenix/StatusView.swift:271` — matches new shape
- `app/Phoenix/StatusView.swift:360` — matches new shape
Verdict: clean

### `KeepMacAwake.isEnabled` at `app/Phoenix/KeepMacAwake.swift:23` (modified)
Old shape: `computed Bool property; getter read UserDefaults, setter persisted and immediately acquired/released the assertion`
New shape: `stored Bool with didSet -> applyEnabled(); init() syncs startup state; failed assertion acquire reverts the property to false before persisting`
Callers found:
- `app/Phoenix/StatusView.swift:437` — matches new shape
- `app/Phoenix/SettingsView.swift:198` — matches new shape
Verdict: clean

## Unreachable conditionals

(none)