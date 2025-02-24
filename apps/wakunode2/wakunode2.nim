when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, tables, strutils, sequtils, os],
  stew/shims/net as stewNet,
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/multihash,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/transports/wstransport,
  libp2p/nameresolving/dnsresolver
import
  ../../waku/common/sqlite,
  ../../waku/common/utils/nat,
  ../../waku/common/logging,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../../waku/v2/node/dnsdisc/waku_dnsdisc,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/wakuswitch,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/waku_metrics,
  ../../waku/v2/protocol/waku_archive,
  ../../waku/v2/protocol/waku_archive/driver/queue_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver,
  ../../waku/v2/protocol/waku_archive/driver/sqlite_driver/migrations as archive_driver_sqlite_migrations,
  ../../waku/v2/protocol/waku_archive/retention_policy,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_capacity,
  ../../waku/v2/protocol/waku_archive/retention_policy/retention_policy_time,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_lightpush,
  ../../waku/v2/protocol/waku_peer_exchange,
  ../../waku/v2/utils/peers,
  ../../waku/v2/utils/wakuenr,
  ./wakunode2_setup_rest,
  ./wakunode2_setup_rpc,
  ./config

when defined(rln):
  import
    ../../waku/v2/protocol/waku_rln_relay


logScope:
  topics = "wakunode"


type SetupResult[T] = Result[T, string]


proc setupDatabaseConnection(dbUrl: string): SetupResult[Option[SqliteDatabase]] =
  ## dbUrl mimics SQLAlchemy Database URL schema
  ## See: https://docs.sqlalchemy.org/en/14/core/engines.html#database-urls
  if dbUrl == "" or dbUrl == "none":
    return ok(none(SqliteDatabase))

  let dbUrlParts = dbUrl.split("://", 1)
  let
    engine = dbUrlParts[0]
    path = dbUrlParts[1]

  let connRes = case engine
    of "sqlite":
      # SQLite engine
      # See: https://docs.sqlalchemy.org/en/14/core/engines.html#sqlite
      SqliteDatabase.new(path)

    else:
      return err("unknown database engine")

  if connRes.isErr():
    return err("failed to init database connection: " & connRes.error)

  ok(some(connRes.value))

proc gatherSqlitePageStats(db: SqliteDatabase): SetupResult[(int64, int64, int64)] =
  let
    pageSize = ?db.getPageSize()
    pageCount = ?db.getPageCount()
    freelistCount = ?db.getFreelistCount()

  ok((pageSize, pageCount, freelistCount))

proc performSqliteVacuum(db: SqliteDatabase): SetupResult[void] =
  ## SQLite database vacuuming
  # TODO: Run vacuuming conditionally based on database page stats
  # if (pageCount > 0 and freelistCount > 0):

  debug "starting sqlite database vacuuming"

  let resVacuum = db.vacuum()
  if resVacuum.isErr():
    return err("failed to execute vacuum: " & resVacuum.error)

  debug "finished sqlite database vacuuming"


const PeerPersistenceDbUrl = "sqlite://peers.db"

proc setupPeerStorage(): SetupResult[Option[WakuPeerStorage]] =
  let db = ?setupDatabaseConnection(PeerPersistenceDbUrl)

  ?peer_store_sqlite_migrations.migrate(db.get())

  let res = WakuPeerStorage.new(db.get())
  if res.isErr():
    return err("failed to init peer store" & res.error)

  ok(some(res.value))


proc setupWakuArchiveRetentionPolicy(retentionPolicy: string): SetupResult[Option[RetentionPolicy]] =
  if retentionPolicy == "" or retentionPolicy == "none":
    return ok(none(RetentionPolicy))

  let rententionPolicyParts = retentionPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]


  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.init(retentionTimeSeconds)
    return ok(some(retPolicy))

  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.init(retentionCapacity)
    return ok(some(retPolicy))

  else:
    return err("unknown retention policy")

proc setupWakuArchiveDriver(dbUrl: string, vacuum: bool, migrate: bool): SetupResult[ArchiveDriver] =
  let db = ?setupDatabaseConnection(dbUrl)

  if db.isSome():
    # SQLite vacuum
    # TODO: Run this only if the database engine is SQLite
    let (pageSize, pageCount, freelistCount) = ?gatherSqlitePageStats(db.get())
    debug "sqlite database page stats", pageSize=pageSize, pages=pageCount, freePages=freelistCount

    if vacuum and (pageCount > 0 and freelistCount > 0):
      ?performSqliteVacuum(db.get())

  # Database migration
    if migrate:
      ?archive_driver_sqlite_migrations.migrate(db.get())

  if db.isSome():
    debug "setting up sqlite waku archive driver"
    let res = SqliteDriver.new(db.get())
    if res.isErr():
      return err("failed to init sqlite archive driver: " & res.error)

    ok(res.value)

  else:
    debug "setting up in-memory waku archive driver"
    let driver = QueueDriver.new()  # Defaults to a capacity of 25.000 messages
    ok(driver)


proc retrieveDynamicBootstrapNodes*(dnsDiscovery: bool, dnsDiscoveryUrl: string, dnsDiscoveryNameServers: seq[ValidIpAddress]): SetupResult[seq[RemotePeerInfo]] =

  if dnsDiscovery and dnsDiscoveryUrl != "":
    # DNS discovery
    debug "Discovering nodes using Waku DNS discovery", url=dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain=domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver)
    if wakuDnsDiscovery.isOk():
      return wakuDnsDiscovery.get().findPeers()
        .mapErr(proc (e: cstring): string = $e)
    else:
      warn "Failed to init Waku DNS discovery"

  debug "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default

proc initNode(conf: WakuNodeConf,
              peerStore: Option[WakuPeerStorage],
              dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[]): SetupResult[WakuNode] =

  ## Setup a basic Waku v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  var dnsResolver: DnsResolver
  if conf.dnsAddrs:
    # Support for DNS multiaddrs
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    dnsResolver = DnsResolver.new(nameServers)

  let
    ## `udpPort` is only supplied to satisfy underlying APIs but is not
    ## actually a supported transport for libp2p traffic.
    udpPort = conf.tcpPort
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat,
                                              clientId,
                                              Port(uint16(conf.tcpPort) + conf.portsShift),
                                              Port(uint16(udpPort) + conf.portsShift))

    dns4DomainName = if conf.dns4DomainName != "": some(conf.dns4DomainName)
                      else: none(string)

    discv5UdpPort = if conf.discv5Discovery: some(Port(uint16(conf.discv5UdpPort) + conf.portsShift))
                    else: none(Port)

    ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if (extIp.isSome() or dns4DomainName.isSome()) and extTcpPort.isNone():
                some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else:
                extTcpPort
    extMultiAddrs = if (conf.extMultiAddrs.len > 0):
                      let extMultiAddrsValidationRes = validateExtMultiAddrs(conf.extMultiAddrs)
                      if extMultiAddrsValidationRes.isErr():
                        return err("invalid external multiaddress: " & extMultiAddrsValidationRes.error)
                      else:
                        extMultiAddrsValidationRes.get()
                    else:
                      @[]

    wakuFlags = initWakuFlags(conf.lightpush,
                              conf.filter,
                              conf.store,
                              conf.relay)

  var node: WakuNode

  let pStorage = if peerStore.isNone(): nil
                 else: peerStore.get()
  try:
    node = WakuNode.new(conf.nodekey,
                        conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift),
                        extIp, extPort,
                        extMultiAddrs,
                        pStorage,
                        conf.maxConnections.int,
                        Port(uint16(conf.websocketPort) + conf.portsShift),
                        conf.websocketSupport,
                        conf.websocketSecureSupport,
                        conf.websocketSecureKeyPath,
                        conf.websocketSecureCertPath,
                        some(wakuFlags),
                        dnsResolver,
                        conf.relayPeerExchange, # We send our own signed peer record when peer exchange enabled
                        dns4DomainName,
                        discv5UdpPort,
                        some(conf.agentString),
                        some(conf.peerStoreCapacity))
  except:
    return err("failed to create waku node instance: " & getCurrentExceptionMsg())

  if conf.discv5Discovery:
    let
      discoveryConfig = DiscoveryConfig.init(
        conf.discv5TableIpLimit, conf.discv5BucketIpLimit, conf.discv5BitsPerHop)

    # select dynamic bootstrap nodes that have an ENR containing a udp port.
    # Discv5 only supports UDP https://github.com/ethereum/devp2p/blob/master/discv5/discv5-theory.md)
    var discv5BootstrapEnrs: seq[enr.Record]
    for n in dynamicBootstrapNodes:
      if n.enr.isSome():
        let
          enr = n.enr.get()
          tenrRes = enr.toTypedRecord()
        if tenrRes.isOk() and (tenrRes.get().udp.isSome() or tenrRes.get().udp6.isSome()):
          discv5BootstrapEnrs.add(enr)

    # parse enrURIs from the configuration and add the resulting ENRs to the discv5BootstrapEnrs seq
    for enrUri in conf.discv5BootstrapNodes:
      addBootstrapNode(enrUri, discv5BootstrapEnrs)

    node.wakuDiscv5 = WakuDiscoveryV5.new(
      extIP, extPort, discv5UdpPort,
      conf.listenAddress,
      discv5UdpPort.get(),
      discv5BootstrapEnrs,
      conf.discv5EnrAutoUpdate,
      keys.PrivateKey(conf.nodekey.skkey),
      wakuFlags,
      [], # Empty enr fields, for now
      node.rng,
      discoveryConfig
    )

  ok(node)

proc setupProtocols(node: WakuNode, conf: WakuNodeConf,
                    archiveDriver: Option[ArchiveDriver],
                    archiveRetentionPolicy: Option[RetentionPolicy]): Future[SetupResult[void]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

  # Mount relay on all nodes
  var peerExchangeHandler = none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome()) # only peers with populated records
                                .mapIt(toRemotePeerInfo(it.record.get()))

      debug "connecting to exchanged peers", src=peer, topic=topic, numPeers=exchangedPeers.len

      # asyncSpawn, as we don't want to block here
      asyncSpawn node.connectToNodes(exchangedPeers, "peer exchange")

    peerExchangeHandler = some(handlePeerExchange)

  if conf.relay:
    try:
      let pubsubTopics = conf.topics.split(" ")
      await mountRelay(node, pubsubTopics, peerExchangeHandler = peerExchangeHandler)
    except:
      return err("failed to mount waku relay protocol: " & getCurrentExceptionMsg())


  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())

  when defined(rln):
    if conf.rlnRelay:

      let rlnConf = WakuRlnConfig(
        rlnRelayDynamic: conf.rlnRelayDynamic,
        rlnRelayPubsubTopic: conf.rlnRelayPubsubTopic,
        rlnRelayContentTopic: conf.rlnRelayContentTopic,
        rlnRelayMembershipIndex: conf.rlnRelayMembershipIndex,
        rlnRelayEthContractAddress: conf.rlnRelayEthContractAddress,
        rlnRelayEthClientAddress: conf.rlnRelayEthClientAddress,
        rlnRelayEthAccountPrivateKey: conf.rlnRelayEthAccountPrivateKey,
        rlnRelayEthAccountAddress: conf.rlnRelayEthAccountAddress,
        rlnRelayCredPath: conf.rlnRelayCredPath,
        rlnRelayCredentialsPassword: conf.rlnRelayCredentialsPassword
      )

      try:
        await node.mountRlnRelay(rlnConf)
      except:
        return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())

  if conf.swap:
    try:
      await mountSwap(node)
      # TODO: Set swap peer, for now should be same as store peer
    except:
      return err("failed to mount waku swap protocol: " & getCurrentExceptionMsg())

  if conf.store:
    # Archive setup
    let messageValidator: MessageValidator = DefaultMessageValidator()
    mountArchive(node, archiveDriver, messageValidator=some(messageValidator), retentionPolicy=archiveRetentionPolicy)

    # Store setup
    try:
      await mountStore(node)
    except:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

    # TODO: Move this to storage setup phase
    if archiveRetentionPolicy.isSome():
      executeMessageRetentionPolicy(node)
      startMessageRetentionPolicyPeriodicTask(node, interval=WakuArchiveDefaultRetentionPolicyInterval)

  if conf.storenode != "":
    try:
      mountStoreClient(node)
      let storenode = parseRemotePeerInfo(conf.storenode)
      node.peerManager.addServicePeer(storenode, WakuStoreCodec)
    except:
      return err("failed to set node waku store peer: " & getCurrentExceptionMsg())

  # NOTE Must be mounted after relay
  if conf.lightpush:
    try:
      await mountLightPush(node)
    except:
      return err("failed to mount waku lightpush protocol: " & getCurrentExceptionMsg())

  if conf.lightpushnode != "":
    try:
      mountLightPushClient(node)
      let lightpushnode = parseRemotePeerInfo(conf.lightpushnode)
      node.peerManager.addServicePeer(lightpushnode, WakuLightPushCodec)
    except:
      return err("failed to set node waku lightpush peer: " & getCurrentExceptionMsg())

  # Filter setup. NOTE Must be mounted after relay
  if conf.filter:
    try:
      await mountFilter(node, filterTimeout = chronos.seconds(conf.filterTimeout))
    except:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

  if conf.filternode != "":
    try:
      await mountFilterClient(node)
      let filternode = parseRemotePeerInfo(conf.filternode)
      node.peerManager.addServicePeer(filternode, WakuFilterCodec)
    except:
      return err("failed to set node waku filter peer: " & getCurrentExceptionMsg())

  # waku peer exchange setup
  if (conf.peerExchangeNode != "") or (conf.peerExchange):
    try:
      await mountPeerExchange(node)
    except:
      return err("failed to mount waku peer-exchange protocol: " & getCurrentExceptionMsg())

    if conf.peerExchangeNode != "":
      try:
        let peerExchangeNode = parseRemotePeerInfo(conf.peerExchangeNode)
        node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)
      except:
        return err("failed to set node waku peer-exchange peer: " & getCurrentExceptionMsg())

  return ok()

proc startNode(node: WakuNode, conf: WakuNodeConf,
               dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]): Future[SetupResult[void]] {.async.} =
  ## Start a configured node and all mounted protocols.
  ## Connect to static nodes and start
  ## keep-alive, if configured.

  # Start Waku v2 node
  try:
    await node.start()
  except:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  # Start discv5 and connect to discovered nodes
  if conf.discv5Discovery:
    try:
      if not await node.startDiscv5():
        error "could not start Discovery v5"
    except:
      return err("failed to start waku discovery v5: " & getCurrentExceptionMsg())

  # Connect to configured static nodes
  if conf.staticnodes.len > 0:
    try:
      await connectToNodes(node, conf.staticnodes, "static")
    except:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())

  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except:
      return err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())

  if conf.peerExchange:
    asyncSpawn runPeerExchangeDiscv5Loop(node.wakuPeerExchange)

  # retrieve and connect to peer exchange peers
  if conf.peerExchangeNode != "":
    info "Retrieving peer info via peer exchange protocol"
    let desiredOutDegree = node.wakuRelay.parameters.d.uint64()
    try:
      discard await node.wakuPeerExchange.request(desiredOutDegree)
    except:
      return err("failed to retrieve peer info via peer exchange protocol: " & getCurrentExceptionMsg())

  # Start keepalive, if enabled
  if conf.keepAlive:
    node.startKeepalive()

  # Maintain relay connections
  if conf.relay:
    node.peerManager.start()

  return ok()

when defined(waku_exp_store_resume):
  proc resumeMessageStore(node: WakuNode, address: string): Future[SetupResult[void]] {.async.} =
    # Resume historical messages, this has to be called after the node has been started
    if address != "":
      return err("empty peer multiaddres")

    var remotePeer: RemotePeerInfo
    try:
      remotePeer = parseRemotePeerInfo(address)
    except:
      return err("invalid peer multiaddress: " & getCurrentExceptionMsg())

    try:
      await node.resume(some(@[remotePeer]))
    except:
      return err("failed to resume messages history: " & getCurrentExceptionMsg())


proc startRpcServer(node: WakuNode, address: ValidIpAddress, port: uint16, portsShift: uint16, conf: WakuNodeConf): SetupResult[void] =
  try:
    startRpcServer(node, address, Port(port + portsShift), conf)
  except:
    return err("failed to start the json-rpc server: " & getCurrentExceptionMsg())

  ok()

proc startRestServer(node: WakuNode, address: ValidIpAddress, port: uint16, portsShift: uint16, conf: WakuNodeConf): SetupResult[void] =
  startRestServer(node, address, Port(port + portsShift), conf)
  ok()

proc startMetricsServer(node: WakuNode, address: ValidIpAddress, port: uint16, portsShift: uint16): SetupResult[void] =
  startMetricsServer(address, Port(port + portsShift))
  ok()


proc startMetricsLogging(): SetupResult[void] =
  startMetricsLog()
  ok()


{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  const versionString = "version / git commit hash: " & git_version

  let confRes = WakuNodeConf.load(version=versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error=confRes.error
    quit(QuitFailure)

  let conf = confRes.get()

  ## Logging setup

  # Adhere to NO_COLOR initiative: https://no-color.org/
  let color = try: not parseBool(os.getEnv("NO_COLOR", "false"))
              except: true

  logging.setupLogLevel(conf.logLevel)
  logging.setupLogFormat(conf.logFormat, color)


  ##############
  # Node setup #
  ##############

  debug "1/7 Setting up storage"

  ## Peer persistence
  var peerStore = none(WakuPeerStorage)

  if conf.peerPersistence:
    let peerStoreRes = setupPeerStorage();
    if peerStoreRes.isOk():
      peerStore = peerStoreRes.get()
    else:
      error "failed to setup peer store", error=peerStoreRes.error
      waku_node_errors.inc(labelValues = ["init_store_failure"])

  ## Waku archive
  var archiveDriver = none(ArchiveDriver)
  var archiveRetentionPolicy = none(RetentionPolicy)

  if conf.store:
    # Message storage
    let dbUrlValidationRes = validateDbUrl(conf.storeMessageDbUrl)
    if dbUrlValidationRes.isErr():
      error "failed to configure the message store database connection", error=dbUrlValidationRes.error
      quit(QuitFailure)

    let archiveDriverRes = setupWakuArchiveDriver(dbUrlValidationRes.get(), vacuum=conf.storeMessageDbVacuum, migrate=conf.storeMessageDbMigration)
    if archiveDriverRes.isOk():
      archiveDriver = some(archiveDriverRes.get())
    else:
      error "failed to configure archive driver", error=archiveDriverRes.error
      quit(QuitFailure)

    # Message store retention policy
    let storeMessageRetentionPolicyRes = validateStoreMessageRetentionPolicy(conf.storeMessageRetentionPolicy)
    if storeMessageRetentionPolicyRes.isErr():
      error "invalid store message retention policy configuration", error=storeMessageRetentionPolicyRes.error
      quit(QuitFailure)

    let archiveRetentionPolicyRes = setupWakuArchiveRetentionPolicy(storeMessageRetentionPolicyRes.get())
    if archiveRetentionPolicyRes.isOk():
      archiveRetentionPolicy = archiveRetentionPolicyRes.get()
    else:
      error "failed to configure the message retention policy", error=archiveRetentionPolicyRes.error
      quit(QuitFailure)

    # TODO: Move retention policy execution here
    # if archiveRetentionPolicy.isSome():
    #   executeMessageRetentionPolicy(node)
    #   startMessageRetentionPolicyPeriodicTask(node, interval=WakuArchiveDefaultRetentionPolicyInterval)


  debug "2/7 Retrieve dynamic bootstrap nodes"

  var dynamicBootstrapNodes: seq[RemotePeerInfo]
  let dynamicBootstrapNodesRes = retrieveDynamicBootstrapNodes(conf.dnsDiscovery, conf.dnsDiscoveryUrl, conf.dnsDiscoveryNameServers)
  if dynamicBootstrapNodesRes.isOk():
    dynamicBootstrapNodes = dynamicBootstrapNodesRes.get()
  else:
    warn "2/7 Retrieving dynamic bootstrap nodes failed. Continuing without dynamic bootstrap nodes.", error=dynamicBootstrapNodesRes.error

  debug "3/7 Initializing node"

  var node: WakuNode  # This is the node we're going to setup using the conf

  let initNodeRes = initNode(conf, peerStore, dynamicBootstrapNodes)
  if initNodeRes.isok():
    node = initNodeRes.get()
  else:
    error "3/7 Initializing node failed. Quitting.", error=initNodeRes.error
    quit(QuitFailure)

  debug "4/7 Mounting protocols"

  let setupProtocolsRes = waitFor setupProtocols(node, conf, archiveDriver, archiveRetentionPolicy)
  if setupProtocolsRes.isErr():
    error "4/7 Mounting protocols failed. Continuing in current state.", error=setupProtocolsRes.error

  debug "5/7 Starting node and mounted protocols"

  let startNodeRes = waitFor startNode(node, conf, dynamicBootstrapNodes)
  if startNodeRes.isErr():
    error "5/7 Starting node and mounted protocols failed. Continuing in current state.", error=startNodeRes.error


  when defined(waku_exp_store_resume):
    # Resume message store on boot
    if conf.storeResumePeer != "":
      let resumeMessageStoreRes = waitFor resumeMessageStore(node, conf.storeResumePeer)
      if resumeMessageStoreRes.isErr():
        error "failed to resume message store from peer node. Continuing in current state", error=resumeMessageStoreRes.error


  debug "6/7 Starting monitoring and external interfaces"

  if conf.rpc:
    let startRpcServerRes = startRpcServer(node, conf.rpcAddress, conf.rpcPort, conf.portsShift, conf)
    if startRpcServerRes.isErr():
      error "6/7 Starting JSON-RPC server failed. Continuing in current state.", error=startRpcServerRes.error

  if conf.rest:
    let startRestServerRes = startRestServer(node, conf.restAddress, conf.restPort, conf.portsShift, conf)
    if startRestServerRes.isErr():
      error "6/7 Starting REST server failed. Continuing in current state.", error=startRestServerRes.error

  if conf.metricsServer:
    let startMetricsServerRes = startMetricsServer(node, conf.metricsServerAddress, conf.metricsServerPort, conf.portsShift)
    if startMetricsServerRes.isErr():
      error "6/7 Starting metrics server failed. Continuing in current state.", error=startMetricsServerRes.error

  if conf.metricsLogging:
    let startMetricsLoggingRes = startMetricsLogging()
    if startMetricsLoggingRes.isErr():
      error "6/7 Starting metrics console logging failed. Continuing in current state.", error=startMetricsLoggingRes.error


  debug "7/7 Setting up shutdown hooks"
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.

  proc asyncStopper(node: WakuNode) {.async.} =
    await node.stop()
    quit(QuitSuccess)

  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after receiving SIGINT"
    asyncSpawn asyncStopper(node)

  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      notice "Shutting down after receiving SIGTERM"
      asyncSpawn asyncStopper(node)

    c_signal(ansi_c.SIGTERM, handleSigterm)

  # Handle SIGSEGV
  when defined(posix):
    proc handleSigsegv(signal: cint) {.noconv.} =
      # Require --debugger:native
      fatal "Shutting down after receiving SIGSEGV", stacktrace=getBacktrace()

      # Not available in -d:release mode
      writeStackTrace()

      waitFor node.stop()
      quit(QuitFailure)

    c_signal(ansi_c.SIGSEGV, handleSigsegv)

  info "Node setup complete"

  runForever()
