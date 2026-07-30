## Connecting to the internal endpoint (the UDS ssh established, or the TCP
## fallback).

import std/asyncdispatch
import std/asyncnet
import std/nativesockets
import powarder/core/types

type
  UpstreamUnhealthyError* = object of CatchableError
    ## Represents a failure to establish a connection to the upstream
    ## (UDS or TCP).

proc dialUpstream*(target: UpstreamTarget): Future[AsyncSocket] {.async.} =
  ## Connects to `target` and returns the established `AsyncSocket`.
  ##
  ## `buffered = false` matters: since `acceptAddr` makes the accepted
  ## child socket inherit the parent's `isBuffered`, keeping everything
  ## unbuffered — including the public listener side — means `recvInto`/
  ## `send` avoid an extra `copyMem` through an internal buffer.
  ##
  ## A connect failure (`ECONNREFUSED` / `ENOENT` etc.) causes `OSError` to
  ## be raised, since `std/asyncdispatch`'s implementation does
  ## `retFuture.fail(newOSError(...))`. It is caught here and converted
  ## into `UpstreamUnhealthyError`, and the socket is always closed.
  case target.kind
  of ukUnix:
    let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE,
        buffered = false)
    try:
      await sock.connectUnix(target.path)
    except CatchableError as e:
      sock.close()
      raise newException(UpstreamUnhealthyError,
          "Failed to connect to UDS " & target.path & ": " & e.msg)
    result = sock
  of ukTcp:
    let sock = newAsyncSocket(buffered = false)
    try:
      await sock.connect("127.0.0.1", target.port)
    except CatchableError as e:
      sock.close()
      raise newException(UpstreamUnhealthyError,
          "Failed to connect to TCP 127.0.0.1:" & $target.port &
          ": " & e.msg)
    result = sock

proc probeUpstream*(target: UpstreamTarget): Future[bool] {.async.} =
  ## Attempts a connection and closes it immediately, returning success as
  ## a bool (for health checks).
  ##
  ## **Important known limitation**: OpenSSH's `channels.c`
  ## `channel_post_port_listener()` calls `port_open_helper()` the instant
  ## `accept()` succeeds (even before a single byte is sent), which sends a
  ## `direct-tcpip` `SSH_MSG_CHANNEL_OPEN` to the remote side. In other
  ## words, **`probeUpstream` always triggers a real connection to the
  ## destination via the bastion** (this cannot be avoided). Therefore
  ## periodic probing is disabled by default, and this should only be used
  ## in situations with a bounded number of calls, such as adopt
  ## determination at daemon startup.
  try:
    let sock = await dialUpstream(target)
    sock.close()
    result = true
  except UpstreamUnhealthyError:
    result = false
