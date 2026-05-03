## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `InstallerView` memberwise initializer at `app/Phoenix/InstallerView.swift:4` (modified)
Old shape: `InstallerView(downloadManager: RuntimeDownloadManager, client: DaemonClient, onDismiss: () -> Void)`
New shape: `InstallerView(downloadManager: RuntimeDownloadManager, client: DaemonClient, keepMacAwake: KeepMacAwake, onDismiss: () -> Void)`
Callers found:
- `app/Phoenix/PhoenixApp.swift:150` — matches new shape
Verdict: clean

### `SettingsView` memberwise initializer at `app/Phoenix/SettingsView.swift:3` (modified)
Old shape: `SettingsView(client: DaemonClient, downloadManager: RuntimeDownloadManager, onDismiss: () -> Void)`
New shape: `SettingsView(client: DaemonClient, downloadManager: RuntimeDownloadManager, keepMacAwake: KeepMacAwake, onDismiss: () -> Void)`
Callers found:
- `app/Phoenix/InstallerView.swift:55` — matches new shape
Verdict: clean

### `StatusView` memberwise initializer at `app/Phoenix/StatusView.swift:171` (modified)
Old shape: `StatusView(client: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder)`
New shape: `StatusView(client: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, keepMacAwake: KeepMacAwake)`
Callers found:
- `app/Phoenix/MenuBarController.swift:38` — matches new shape
Verdict: clean

### `MenuBarController.init` at `app/Phoenix/MenuBarController.swift:27` (modified)
Old shape: `init(daemonClient: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, isDev: Bool)`
New shape: `init(daemonClient: DaemonClient, downloadManager: RuntimeDownloadManager, appUpdater: AppUpdater, installerController: InstallerWindowController, audioRecorder: AudioRecorder, keepMacAwake: KeepMacAwake, isDev: Bool)`
Callers found:
- `app/Phoenix/PhoenixApp.swift:88` — matches new shape
Verdict: clean

### `InstallerWindowController.show` at `app/Phoenix/PhoenixApp.swift:140` (modified)
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

### `KeepMacAwake` actor isolation at `app/Phoenix/KeepMacAwake.swift:14` (modified)
Old shape: `@Observable final class KeepMacAwake`
New shape: `@Observable @MainActor final class KeepMacAwake`
Callers found:
- `app/Phoenix/PhoenixApp.swift:42` — matches new shape; containing `PhoenixAppDelegate` is `@MainActor` at `app/Phoenix/PhoenixApp.swift:36`
- `app/Phoenix/MenuBarController.swift:33` — matches new shape; containing `MenuBarController` is `@MainActor` at `app/Phoenix/MenuBarController.swift:18`
- `app/Phoenix/InstallerView.swift:7` — matches new shape; SwiftUI view stores and passes `KeepMacAwake`
- `app/Phoenix/SettingsView.swift:6` — matches new shape; SwiftUI view stores and binds `KeepMacAwake`
- `app/Phoenix/StatusView.swift:177` — matches new shape; SwiftUI view stores and binds `KeepMacAwake`
Verdict: clean

### `KeepMacAwake.isEnabled` at `app/Phoenix/KeepMacAwake.swift:23` (modified)
Old shape: `var isEnabled: Bool { get set }` computed property, persisted in setter
New shape: `var isEnabled: Bool` stored observable property with `didSet`, persists resolved value after applying assertion state
Callers found:
- `app/Phoenix/SettingsView.swift:198` — matches new shape; SwiftUI `Toggle` binds to `Bool`
- `app/Phoenix/StatusView.swift:437` — matches new shape; SwiftUI `Toggle` binds to `Bool`
Verdict: clean

## Unreachable conditionals

(none)