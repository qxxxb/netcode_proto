import
  logging,
  net,
  nativesockets,
  times,
  os,
  tables,
  hashes,
  strformat,
  options,
  strscans,
  sets

proc initLogging() =
  addHandler(newConsoleLogger())
  addHandler(
    newFileLogger(
      "server.log",
      mode = fmWrite,
      levelThreshold = lvlAll,
      fmtStr = verboseFmtStr
    )
  )

type Tick = uint32

type State = object
  tick: Tick

var state: State
const tickDuration = initDuration(milliseconds = 20)

# Number of ticks before running netcode. In other words, the number of ticks
# before receiving and sending packets.
# Units: ticks
const netPeriod = 1

proc ticksToDuration*(ticks: Tick): Duration =
  ticks.int64() * tickDuration

proc shouldRunNet(state: State): bool =
  state.tick mod netPeriod == 0

type SendState {.pure.} = enum
  ## What is being sent to the client
  None,
  Connecting,
  GameSnapshot,
  Recovery

type RecvState {.pure.} = enum
  ## What is being received from the client
  None,
  GameInput

type ClientState = object
  sendState: SendState
  recvState: RecvState
  ackedTick: Tick # The last time that the client acked a snapshot, Units: tick

type ClientKey = object
  address: string
  port: Port

type Client = object
  state: ClientState

proc initClientKey(address: string, port: Port): ClientKey =
  ClientKey(
    address: address,
    port: port
  )

proc initClient(): Client =
  Client(
    state: ClientState(
      sendState: SendState.None,
      recvState: RecvState.None
    )
  )

proc hash*(clientKey: ClientKey): Hash =
  var h: Hash = 0
  h = h !& hash(clientKey.address)
  h = h !& hash(clientKey.port)
  result = !$h

proc ticksSinceAck(client: Client): Tick =
  ## Duration since last ack, Units: ticks
  state.tick - client.state.ackedTick

proc shouldDisconnect(client: Client): bool =
  const preDisconnectDuration: Tick = netPeriod * 500
  client.ticksSinceAck() > preDisconnectDuration

proc shouldBeRecovery(client: Client): bool =
  const preRecoveryDuration: Tick = netPeriod * 50
  client.ticksSinceAck() > preRecoveryDuration

proc shouldSendSnapshot(client: Client): bool =
  proc snapshotPeriod(sendState: SendState): Tick =
    ## Duration between sending snapshots to clients in `sendState`.
    case sendState
    of SendState.Connecting: netPeriod * 10
    of SendState.Recovery: netPeriod * 50
    else: netPeriod

  proc snapshotPeriod(client: Client): Tick =
    client.state.sendState.snapshotPeriod()

  case client.state.sendState
  of SendState.GameSnapshot: true
  of SendState.Connecting, SendState.Recovery:
    debug "ackedTick: ", client.state.ackedTick
    debug "ticksSinceAck: ", client.ticksSinceAck()
    debug "snapShotPeriod: ", client.snapshotPeriod()
    client.ticksSinceAck() > client.snapshotPeriod()
  else: false

type Net = ref object
  socketHandle: SocketHandle
  socket: Socket
  clients: TableRef[ClientKey, Client]

proc newNet(): Net =
  new result
  # TODO: Be Ipv4 and Ipv6 agnostic.
  # Setting it to anything other than `AF_INET` does not work. Seems to be a
  # problem with Nim libraries
  result.socketHandle = createNativeSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  result.socket = newSocket(
    result.socketHandle,
    AF_INET,
    SOCK_DGRAM,
    IPPROTO_UDP
  )
  result.socketHandle.setBlocking(false)
  result.socket.bindAddr(Port(2000))

  result.clients = newTable[ClientKey, Client]()

proc close(net: Net) =
  net.socket.close()

proc sendInfo(net: Net, clientKey: ClientKey) =
  net.socket.sendTo(clientKey.address, clientKey.port, "Welcome to my server")
  info &"Sent info to {clientKey.address}:{clientKey.port}"

proc connect(net: Net, clientKey: ClientKey) =
  var client = initClient()
  client.state.recvState = RecvState.GameInput
  client.state.sendState = SendState.Connecting
  net.clients[clientKey] = client
  info &"Connected {clientKey.address}:{clientKey.port}"

proc disconnect(net: Net, clientKey: ClientKey) =
  if clientKey in net.clients:
    net.clients.del(clientKey)
    info &"Disconnected {clientKey.address}:{clientKey.port}"
  else:
    warn "Got disconnect from unconnected client"

proc sendSnapshot(net: Net, clientKey: ClientKey) =
  net.socket.sendTo(
    clientKey.address,
    clientKey.port,
    &"[{state.tick}] World snapshot"
  )
  info(
    &"Sent snapshot at tick {state.tick} to" &
    &" {clientKey.address}:{clientKey.port}"
  )

proc recv(net: Net) =
  const data_capacity = 1024
  var data = newStringOfCap(data_capacity)
  var senderAddress: string
  var senderPort: Port
  var recvLen: int

  # Loop until there are no more messages in the socket
  while true:
    try:
      recvLen = net.socket.recvFrom(
        data,
        length = data_capacity,
        senderAddress,
        senderPort,
        flags = 0'i32
      )
    except OSError:
      debug &"No messages in socket ({recvLen})"
      break

    if recvLen > 0:
      info &"Recv [{senderAddress}:{senderPort}] ({recvLen}): {data}"

      var clientKey = initClientKey(senderAddress, senderPort)
      debug "Clients: ", net.clients

      type ParsedData = object
        ackedTick: int

      var parsedData = ParsedData()

      if data == "Info request":
        net.sendInfo(clientKey)
      elif data == "Connect":
        net.connect(clientKey)
      elif data == "Disconnect":
        net.disconnect(clientKey)
      elif data.scanf("[$i] Ack", parsedData.ackedTick):
        if clientKey in net.clients:
          let ackedTick = parsedData.ackedTick.Tick()
          net.clients[clientKey].state.ackedTick = ackedTick
          net.clients[clientKey].state.sendState = SendState.GameSnapshot
          info &"Acked snapshot {ackedTick} from {senderAddress}:{senderPort}"
        else:
          warn "Got ack from unconnected client"

      else:
        # TODO: Save inputs and process
        discard

proc send(net: Net) =
  var clientsToDisconnect = initHashSet[ClientKey]()

  for clientKey, client in net.clients:
    debug "Pre-send"
    debug "client.sendState: ", client.state.sendState
    debug "client.recvState: ", client.state.recvState
    debug "client.ticksSinceAck(): ", client.ticksSinceAck()

    if client.shouldDisconnect():
      clientsToDisconnect.incl(clientKey)
    else:
      if client.shouldBeRecovery():
        net.clients[clientKey].state.sendState = SendState.Recovery

      if client.shouldSendSnapshot():
        net.sendSnapshot(clientKey)

  for clientKey in clientsToDisconnect:
    net.disconnect(clientKey)

proc update() =
  discard

proc main() =
  initLogging()

  state = State()
  var net = newNet()
  defer: net.close()

  # Every 20 milliseconds, process all clients
  while true:
    let start = times.getTime()

    if state.shouldRunNet():
      net.recv()

    update()

    if state.shouldRunNet():
      net.send()

    # Sleep until next tick needed
    let elapsed = getTime() - start
    let sleepDuration = tickDuration - elapsed
    if (sleepDuration > DurationZero):
      debug "Sleep"
      sleep(sleepDuration.inMilliseconds().int())
    else:
      warn "Tick ran for longer than `tickDuration`"
      warn "`tickDuration - elapsed`: ", sleepDuration

    state.tick.inc()

main()
