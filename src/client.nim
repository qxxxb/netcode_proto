import
  logging,
  net,
  nativesockets,
  times,
  os,
  strformat,
  strscans

proc initLogging() =
  addHandler(newConsoleLogger())
  addHandler(
    newFileLogger(
      "client.log",
      mode = fmWrite,
      levelThreshold = lvlAll,
      fmtStr = verboseFmtStr
    )
  )

type Tick = uint32

type SendState {.pure.} = enum
  ## What is being sent to the server.
  None,
  Info,
  Connect,
  Disconnect,
  GameInput

type RecvState {.pure.} = enum
  ## What is being received from the server
  None,
  Info,
  GameSnapshot

type State = object
  tick: Tick
  sendState: SendState
  recvState: RecvState
  requestInfo: bool ## Whether we should request server info

var state: State
const tickDuration = initDuration(milliseconds = 20)

proc main() =
  initLogging()

  state = State(
    sendState: SendState.Info,
    recvState: RecvState.None
  )

  var socketFd = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  var socket = newSocket(socketFd, AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  defer: socket.close()

  socketFd.setBlocking(false)

  const serverAddress = "localhost"
  let serverPort = Port(2000)

  # TODO: Handle when the server cannot be connected to
  # TODO: Design a protocol

  var startTime = getTime()

  # Send inputs to server
  while true:
    let start = times.getTime()

    if getTime() - startTime > initDuration(seconds = 3):
      state.sendState = SendState.Disconnect

    debug "Pre-send"
    debug "state.sendState: ", state.sendState
    debug "state.recvState: ", state.recvState

    case state.sendState
    of SendState.None: discard
    of SendState.Info:
        # TODO: Request server-list from master-server
        # TODO: Request info of server(s)
        debug "Request info"
        socket.sendTo(serverAddress, serverPort, "Info request")
        state.sendState = SendState.None
        state.recvState = RecvState.Info

    of SendState.Connect:
      debug "Connect"
      socket.sendTo(serverAddress, serverPort, "Connect")

      # TODO: Send a connect request every 2 seconds until connected
      state.sendState = SendState.None
      state.recvState = RecvState.GameSnapshot

    of SendState.Disconnect:
      debug "Disconnect"
      socket.sendTo(serverAddress, serverPort, "Disconnect")

      state.sendState = SendState.None
      state.recvState = RecvState.None
      break

    of SendState.GameInput:
      socket.sendTo(serverAddress, serverPort, "Client input")
      debug "Sent client input to server"

    debug "Pre-recv"
    debug "state.sendState: ", state.sendState
    debug "state.recvState: ", state.recvState

    case state.recvState
    of RecvState.None: discard
    else:
      const data_capacity = 1024
      var data = newStringOfCap(data_capacity)
      var senderAddress: string
      var senderPort: Port
      var recvLen: int
      try:
        recvLen = socket.recvFrom(
          data,
          length = data_capacity,
          address = senderAddress,
          port = senderPort,
          flags = 0'i32
        )
      except OSError:
        debug &"No messages in socket ({recvLen})"

      if recvLen > 0:
        info &"Recv [{senderAddress}:{senderPort}] ({recvLen}): {data}"

        # TODO: Verify that sender is server.
        # Don't know if this is necessary

        # Process the data
        case state.recvState
        of RecvState.Info:
          info &"Server info: {data}"

          # TODO: This would not necessarily be triggered here
          state.sendState = SendState.Connect
        of RecvState.GameSnapshot:
          type ParsedData = object
            snapshotTick: int

          var parsedData = ParsedData()

          if data.scanf("[$i] World snapshot", parsedData.snapshotTick):
            let snapshotTick = parsedData.snapshotTick.Tick()
            info &"Received world snapshot at tick {snapshotTick}"
            socket.sendTo(serverAddress, serverPort, &"[{snapshotTick}] Ack")
            debug &"Sent ack for tick {snapshotTick}"
          else:
            warn &"Can't parse game snapshot: `{data}`"

          state.sendState = SendState.GameInput
        else: discard

    # Sleep until next tick needed
    let elapsed = getTime() - start
    let sleepDuration = tickDuration - elapsed
    if (sleepDuration > DurationZero):
      debug "Sleep"
      sleep(sleepDuration.inMilliseconds().int())
    else:
      warn "Tick ran for longer than `tickDuration`"
      warn "`tickDuration - elapsed`: ", sleepDuration

main()
