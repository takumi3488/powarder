## A module that only collects the types, constants, and pure helpers
## shared by the `platform/service*` family.
##
## ### Why this module exists (resolving the circular import)
##
## Previously, `service.nim` held these types directly, and while
## `service_darwin` / `service_linux` imported `service.nim` to use those
## types, `service.nim` itself also imported `service_darwin` /
## `service_linux` based on OS detection (= a mutual import among all
## three modules).
##
## Nim tolerates this kind of circular import, but there is a trap where
## **the result changes depending on which module is compiled first (the
## entry module)**. If `service_darwin` / `service_linux` are imported
## first, or compiled standalone as the root module, Nim resolves the
## cycle as a "partially compiled empty module," and it fails with
## "undeclared identifier."
##
## So the types, constants, and pure helpers were extracted into this
## `service_types`, making the dependency direction
##
##   service_types  ←  service_darwin / service_linux  ←  service
##
## one-way. `service_types` never imports any other
## `powarder/platform/service*` module at all (only `std/*`), so no matter
## what order things are imported starting from here, no cycle occurs.
##
## IMPORTANT for anyone touching this module: **moving types or helpers
## back into `service.nim` breaks this one-way dependency structure and
## brings back the circular import.** When adding a new type, constant, or
## pure helper, place here only what is needed by both `service_darwin`
## and `service_linux`.

type
  ServiceStatus* = enum
    ssNotInstalled ## No unit/plist file exists
    ssInstalled    ## Registered but not running
    ssRunning      ## Registered and running
    ssUnknown      ## The launchctl / systemctl query itself failed

  ServiceInfo* = object
    label*: string      ## "dev.powarder.daemon"
    unitPath*: string   ## Path to the plist / unit file
    status*: ServiceStatus
    notes*: seq[string] ## Guidance for the user (loginctl enable-linger, etc.)

const
  commonServiceLabel = "dev.powarder.daemon"

proc serviceLabel*(): string =
  ## The same label string regardless of OS. Used as macOS's plist `Label`
  ## key, and as an identifier within guidance messages (on the systemd
  ## side, the unit file name itself becomes `powarder.service`, but this
  ## string is reused as the concept corresponding to `Label`).
  commonServiceLabel
