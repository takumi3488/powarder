## Registering as an OS service for persistent running (common interface).
##
## Called from `powarder daemon install` / `uninstall`. The actual
## registration processing for macOS (launchd) / Linux (systemd --user) is
## separated into `platform/service_darwin` / `platform/service_linux`
## respectively, and this module itself only has:
## - the common types (`ServiceStatus` / `ServiceInfo`) and `serviceLabel`,
##   imported and re-exported from `platform/service_types`
## - dispatching based on OS detection (`when defined(macosx)` /
##   `when defined(linux)`)
##
## ### IMPORTANT: the most critical design decision
##
## The correct behavior is "do not restart on exit 0; restart only on a
## crash."
## - macOS: set launchd's `KeepAlive` to `SuccessfulExit = false`
## - Linux: use systemd's `Restart=on-failure` (**not** `always`)
##
## Getting this backwards means `powarder daemon stop` (= the process
## exiting with exit 0) gets immediately restarted and can never be
## stopped, or conversely that it never recovers even after a crash. This
## is explicitly verified in `tests/tservice.nim`.
##
## `renderUnitFile` is made a **pure function** (it performs no file I/O and
## never invokes `launchctl` / `systemctl` at all). The policy for tests is
## to verify only the generated string, so as not to pollute the real
## environment (actual launchd / systemd registration).
##
## ### Direction of dependencies (resolving the circular import)
##
## Previously, `service_darwin` / `service_linux` imported this module to
## get the types, while this module also imported those two based on OS
## detection, forming a structure where the three modules imported each
## other in a cycle. Nim tolerates this kind of cycle, but there is a trap
## where, if `service_darwin` / `service_linux` are imported first, or
## compiled standalone as the root module, Nim resolves the cycle as a
## "partially compiled empty module" and fails with "undeclared
## identifier."
##
## So the types, constants, and `serviceLabel` were extracted into
## `platform/service_types`. The dependency becomes the one-way chain
## `service_types` <- `service_darwin` / `service_linux` <- `service`, and
## no cycle occurs. Thanks to `export service_types`, existing callers
## (such as `cli/dispatch.nim`) can keep using `ServiceInfo` etc. as-is with
## just `import powarder/platform/service`.
##
## On an unsupported OS (neither macOS nor Linux), rather than silently
## doing nothing, it explicitly fails by raising `OSError`.

import powarder/platform/service_types
export service_types

when defined(macosx):
  import powarder/platform/service_darwin as impl
elif defined(linux):
  import powarder/platform/service_linux as impl

when defined(macosx) or defined(linux):
  proc unitFilePath*(): string =
    ## Path to the plist / unit file.
    impl.unitFilePath()

  proc renderUnitFile*(exePath: string; configPath = ""): string =
    ## Generates the contents of the plist / unit file. **Pure function**
    ## (for testing).
    impl.renderUnitFile(exePath, configPath)

  proc installService*(exePath: string; configPath = ""): ServiceInfo =
    ## Writes out the unit file and actually registers it via `launchctl` /
    ## `systemctl`.
    impl.installService(exePath, configPath)

  proc uninstallService*(): ServiceInfo =
    ## Deregisters it and deletes the unit file.
    impl.uninstallService()

  proc serviceStatus*(): ServiceInfo =
    ## Queries the current registration status.
    impl.serviceStatus()
else:
  proc unsupportedOsMsg(): string =
    "powarder daemon install/uninstall is not supported on this OS " &
      "(only macOS launchd and Linux systemd --user are supported)"

  proc unitFilePath*(): string =
    raise newException(OSError, unsupportedOsMsg())

  proc renderUnitFile*(exePath: string; configPath = ""): string =
    raise newException(OSError, unsupportedOsMsg())

  proc installService*(exePath: string; configPath = ""): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())

  proc uninstallService*(): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())

  proc serviceStatus*(): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())
