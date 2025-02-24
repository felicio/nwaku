when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sequtils, tables, times, os, deques],
  chronicles, options, chronos, stint,
  confutils,
  strutils,
  web3, json,
  web3/ethtypes,
  eth/keys,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  stew/results,
  stew/[byteutils, arrayops]
import
  ./rln,
  ./conversion_utils,
  ./constants,
  ./protocol_types,
  ./protocol_metrics
import
  ../../utils/time,
  ../../utils/keyfile,
  ../waku_message,
  ../waku_relay

logScope:
  topics = "waku rln_relay"

type WakuRlnConfig* = object
    rlnRelayDynamic*: bool
    rlnRelayPubsubTopic*: PubsubTopic
    rlnRelayContentTopic*: ContentTopic
    rlnRelayMembershipIndex*: uint
    rlnRelayEthContractAddress*: string
    rlnRelayEthClientAddress*: string
    rlnRelayEthAccountPrivateKey*: string
    rlnRelayEthAccountAddress*: string
    rlnRelayCredPath*: string
    rlnRelayCredentialsPassword*: string

type
  SpamHandler* = proc(wakuMessage: WakuMessage): void {.gcsafe, closure, raises: [Defect].}
  RegistrationHandler* = proc(txHash: string): void {.gcsafe, closure, raises: [Defect].}
  GroupUpdateHandler* = proc(blockNumber: BlockNumber,
                             members: seq[MembershipTuple]): RlnRelayResult[void] {.gcsafe.}
  MembershipTuple* = tuple[index: MembershipIndex, idComm: IDCommitment]

# membership contract interface
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # TODO the followings are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

proc inHex*(value:
                   IdentityTrapdoor or
                   IdentityNullifier or
                   IdentitySecretHash or
                   IDCommitment or
                   MerkleNode or
                   Nullifier or
                   Epoch or
                  RlnIdentifier
                   ): string =
  var valueHex = UInt256.fromBytesLE(value)
  valueHex = valueHex.toHex()
  # We pad leading zeroes
  while valueHex.len < value.len * 2:
    valueHex = "0" & valueHex
  return valueHex

proc register*(idComm: IDCommitment, ethAccountAddress: Option[Address], ethAccountPrivKey: keys.PrivateKey, ethClientAddress: string, membershipContractAddress: Address, registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)): Future[Result[MembershipIndex, string]] {.async.} =
  # TODO may need to also get eth Account Private Key as PrivateKey
  ## registers the idComm  into the membership contract whose address is in rlnPeer.membershipContractAddress

  var web3: Web3
  try: # check if the Ethereum client is reachable
    web3 = await newWeb3(ethClientAddress)
  except:
    return err("could not connect to the Ethereum client")

  if ethAccountAddress.isSome():
    web3.defaultAccount = ethAccountAddress.get()
  # set the account private key
  web3.privateKey = some(ethAccountPrivKey)
  #  set the gas price twice the suggested price in order for the fast mining
  let gasPrice = int(await web3.provider.eth_gasPrice()) * 2

  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MembershipFee))
  # does the signing using the provided key
  # web3.privateKey = some(ethAccountPrivateKey)
  var sender = web3.contractSender(MembershipContract, membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address

  debug "registering an id commitment", idComm=idComm.inHex()
  let pk = idComm.toUInt256()

  var txHash: TxHash
  try: # send the registration transaction and check if any error occurs
    txHash = await sender.register(pk).send(value = MembershipFee, gasPrice = gasPrice)
  except ValueError as e:
    return err("registration transaction failed: " & e.msg)

  let tsReceipt = await web3.getMinedTransactionReceipt(txHash)

  # the receipt topic holds the hash of signature of the raised events
  let firstTopic = tsReceipt.logs[0].topics[0]
  # the hash of the signature of MemberRegistered(uint256,uint256) event is equal to the following hex value
  if firstTopic[0..65] != "0x5a92c2530f207992057b9c3e544108ffce3beda4a63719f316967c49bf6159d2":
    return err("invalid event signature hash")

  # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
  # data = pk encoded as 256 bits || index encoded as 256 bits
  let arguments = tsReceipt.logs[0].data
  debug "tx log data", arguments=arguments
  let
    argumentsBytes = arguments.hexToSeqByte()
    # In TX log data, uints are encoded in big endian
    eventIdCommUint = UInt256.fromBytesBE(argumentsBytes[0..31])
    eventIndex =  UInt256.fromBytesBE(argumentsBytes[32..^1])
    eventIdComm = eventIdCommUint.toIDCommitment()
  debug "the identity commitment key extracted from tx log", eventIdComm=eventIdComm.inHex()
  debug "the index of registered identity commitment key", eventIndex=eventIndex

  if eventIdComm != idComm:
    return err("invalid id commitment key")

  await web3.close()

  if registrationHandler.isSome():
    let handler = registrationHandler.get
    handler(toHex(txHash))
  return ok(toMembershipIndex(eventIndex))

proc register*(rlnPeer: WakuRLNRelay, registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)): Future[RlnRelayResult[bool]] {.async.} =
  ## registers the public key of the rlnPeer which is rlnPeer.identityCredential.publicKey
  ## into the membership contract whose address is in rlnPeer.membershipContractAddress
  let pk = rlnPeer.identityCredential.idCommitment
  let regResult = await register(idComm = pk, ethAccountAddress = rlnPeer.ethAccountAddress, ethAccountPrivKey = rlnPeer.ethAccountPrivateKey.get(), ethClientAddress = rlnPeer.ethClientAddress, membershipContractAddress = rlnPeer.membershipContractAddress, registrationHandler = registrationHandler)
  if regResult.isErr:
    return err(regResult.error())
  return ok(true)

proc updateValidRootQueue*(wakuRlnRelay: WakuRLNRelay, root: MerkleNode): void =
  ## updates the valid Merkle root queue with the latest root and pops the oldest one when the capacity of `AcceptableRootWindowSize` is reached
  let overflowCount = wakuRlnRelay.validMerkleRoots.len() - AcceptableRootWindowSize
  if overflowCount >= 0:
    # Delete the oldest `overflowCount` elements in the deque (index 0..`overflowCount`)
    for i in 0..overflowCount:
      wakuRlnRelay.validMerkleRoots.popFirst()
  # Push the next root into the queue
  wakuRlnRelay.validMerkleRoots.addLast(root)

proc insertMembers*(wakuRlnRelay: WakuRLNRelay,
                    index: MembershipIndex,
                    idComms: seq[IDCommitment]): RlnRelayResult[void] =
  ## inserts a sequence of id commitments into the local merkle tree, and adds the changed root to the
  ## queue of valid roots
  ## Returns an error if the insertion fails
  waku_rln_membership_insertion_duration_seconds.nanosecondTime:
    let actionSucceeded = wakuRlnRelay.rlnInstance.insertMembers(index, idComms)
  if not actionSucceeded:
    return err("could not insert id commitments into the merkle tree")

  let rootAfterUpdate = ?wakuRlnRelay.rlnInstance.getMerkleRoot()
  wakuRlnRelay.updateValidRootQueue(rootAfterUpdate)
  return ok()

proc removeMember*(wakuRlnRelay: WakuRLNRelay, index: MembershipIndex): RlnRelayResult[void] =
  ## removes a commitment from the local merkle tree at `index`, and adds the changed root to the
  ## queue of valid roots
  ## Returns an error if the removal fails

  let actionSucceeded = wakuRlnRelay.rlnInstance.removeMember(index)
  if not actionSucceeded:
    return err("could not remove id commitment from the merkle tree")

  let rootAfterUpdate = ?wakuRlnRelay.rlnInstance.getMerkleRoot()
  wakuRlnRelay.updateValidRootQueue(rootAfterUpdate)
  return ok()

proc validateRoot*(wakuRlnRelay: WakuRLNRelay, root: MerkleNode): bool =
  ## Validate against the window of roots stored in wakuRlnRelay.validMerkleRoots
  return root in wakuRlnRelay.validMerkleRoots

proc calcMerkleRoot*(list: seq[IDCommitment]): RlnRelayResult[string] =
  ## returns the root of the Merkle tree that is computed from the supplied list
  ## the root is in hexadecimal format
  ## Returns an error if the computation fails

  let rlnInstance = createRLNInstance()
  if rlnInstance.isErr():
    return err("could not create rln instance: " & rlnInstance.error())
  let rln = rlnInstance.get()

  # create a Merkle tree
  let membersAdded = rln.insertMembers(0, list)
  if not membersAdded:
    return err("could not insert members into the tree")
  let root = rln.getMerkleRoot().value().inHex()
  return ok(root)

proc createMembershipList*(n: int): RlnRelayResult[(
    seq[(string, string, string, string)], string
  )] =
  ## createMembershipList produces a sequence of identity credentials in the form of (identity trapdoor, identity nullifier, identity secret hash, id commitment) in the hexadecimal format
  ## this proc also returns the root of a Merkle tree constructed out of the identity commitment keys of the generated list
  ## the output of this proc is used to initialize a static group keys (to test waku-rln-relay in the off-chain mode)
  ## Returns an error if it cannot create the membership list

  # initialize a Merkle tree
  let rlnInstance = createRLNInstance()
  if rlnInstance.isErr():
    return err("could not create rln instance: " & rlnInstance.error())
  let rln = rlnInstance.get()

  var output = newSeq[(string, string, string, string)]()
  var idCommitments = newSeq[IDCommitment]()

  for i in 0..n-1:
    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    if idCredentialRes.isErr():
      return err("could not generate an identity credential: " & idCredentialRes.error())
    let idCredential = idCredentialRes.get()
    let idTuple = (idCredential.idTrapdoor.inHex(), idCredential.idNullifier.inHex(), idCredential.idSecretHash.inHex(), idCredential.idCommitment.inHex())
    output.add(idTuple)
    idCommitments.add(idCredential.idCommitment)

  # Insert members into tree
  let membersAdded = rln.insertMembers(0, idCommitments)
  if not membersAdded:
    return err("could not insert members into the tree")

  let root = rln.getMerkleRoot().value().inHex()
  return ok((output, root))

proc rlnRelayStaticSetUp*(rlnRelayMembershipIndex: MembershipIndex): RlnRelayResult[(Option[seq[
    IDCommitment]], Option[IdentityCredential], Option[
    MembershipIndex])] =
  ## rlnRelayStaticSetUp is a proc that is used to initialize the static group keys and the static membership index
  ## this proc is used to test waku-rln-relay in the off-chain mode
  ## it returns the static group id commitments, the static identity credentials, and the static membership indexes
  ## Returns an error if it cannot initialize the static group keys and the static membership index
  let
    # static group
    groupKeys = StaticGroupKeys
    groupSize = StaticGroupSize

  debug "rln-relay membership index", rlnRelayMembershipIndex

  # validate the user-supplied membership index
  if rlnRelayMembershipIndex < MembershipIndex(0) or rlnRelayMembershipIndex >=
      MembershipIndex(groupSize):
    error "wrong membership index"
    return ok((none(seq[IDCommitment]), none(IdentityCredential), none(MembershipIndex)))

  # prepare the outputs from the static group keys
  let
    # create a sequence of IdentityCredentials from the group keys (group keys are in string format)
    groupIdCredentialsRes = groupKeys.toIdentityCredentials()

  if groupIdCredentialsRes.isErr():
    return err("could not convert the group keys to IdentityCredentials: " &
        groupIdCredentialsRes.error())

  let
    groupIdCredentials = groupIdCredentialsRes.get()
    # extract id commitment keys
    groupIDCommitments = groupIdCredentials.mapIt(it.idCommitment)
    groupIDCommitmentsOpt = some(groupIDCommitments)
    # user selected rln membership credential
    groupIdCredentialsOpt = some(groupIdCredentials[rlnRelayMembershipIndex])
    memIndexOpt = some(rlnRelayMembershipIndex)

  return ok((groupIDCommitmentsOpt, groupIdCredentialsOpt, memIndexOpt))

proc calcEpoch*(t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value
  let e = uint64(t/EpochUnitSeconds)
  return toEpoch(e)

proc hasDuplicate*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `msg`'s epoch and nullifier but different Shamir secret shares
  ## otherwise, returns false
  ## Returns an error if it cannot check for duplicates

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return err("failed to decode the RLN proof")

  let proof = decodeRes.get()

  # extract the proof metadata of the supplied `msg`
  let proofMD = ProofMetadata(
    nullifier: proof.nullifier,
    shareX: proof.shareX,
    shareY: proof.shareY
  )

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(proof.epoch):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[proof.epoch].contains(proofMD):
      # there is an identical record, ignore rhe mag
      return ok(false)

    # check for a message with the same nullifier but different secret shares
    let matched = rlnPeer.nullifierLog[proof.epoch].filterIt((
        it.nullifier == proofMD.nullifier) and ((it.shareX != proofMD.shareX) or
        (it.shareY != proofMD.shareY)))

    if matched.len != 0:
      # there is a duplicate
      return ok(true)

    # there is no duplicate
    return ok(false)

  except KeyError as e:
    return err("the epoch was not found")

proc updateLog*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## extracts  the `ProofMetadata` of the supplied messages `msg` and
  ## saves it in the `nullifierLog` of the `rlnPeer`
  ## Returns an error if it cannot update the log

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return err("failed to decode the RLN proof")

  let proof = decodeRes.get()

  # extract the proof metadata of the supplied `msg`
  let proofMD = ProofMetadata(
    nullifier: proof.nullifier,
    shareX: proof.shareX,
    shareY: proof.shareY
  )
  debug "proof metadata", proofMD = proofMD

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(proof.epoch):
    rlnPeer.nullifierLog[proof.epoch] = @[proofMD]
    return ok(true)

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[proof.epoch].contains(proofMD):
      return ok(true)
    # add proofMD to the log
    rlnPeer.nullifierLog[proof.epoch].add(proofMD)
    return ok(true)
  except KeyError as e:
    return err("the epoch was not found")

proc getCurrentEpoch*(): Epoch =
  ## gets the current rln Epoch time
  return calcEpoch(epochTime())

proc absDiff*(e1, e2: Epoch): uint64 =
  ## returns the absolute difference between the two rln `Epoch`s `e1` and `e2`
  ## i.e., e1 - e2

  # convert epochs to their corresponding unsigned numerical values
  let
    epoch1 = fromEpoch(e1)
    epoch2 = fromEpoch(e2)

  # Manually perform an `abs` calculation
  if epoch1 > epoch2:
    return epoch1 - epoch2
  else:
    return epoch2 - epoch1

proc validateMessage*(rlnPeer: WakuRLNRelay, msg: WakuMessage,
    timeOption: Option[float64] = none(float64)): MessageValidationResult =
  ## validate the supplied `msg` based on the waku-rln-relay routing protocol i.e.,
  ## the `msg`'s epoch is within MaxEpochGap of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that
  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return MessageValidationResult.Invalid

  let proof = decodeRes.get()

  # track message count for metrics
  waku_rln_messages_total.inc()

  #  checks if the `msg`'s epoch is far from the current epoch
  # it corresponds to the validation of rln external nullifier
  var epoch: Epoch
  if timeOption.isSome():
    epoch = calcEpoch(timeOption.get())
  else:
    # get current rln epoch
    epoch = getCurrentEpoch()

  debug "current epoch", currentEpoch = fromEpoch(epoch)
  let
    msgEpoch = proof.epoch
    # calculate the gaps
    gap = absDiff(epoch, msgEpoch)

  debug "message epoch", msgEpoch = fromEpoch(msgEpoch)

  # validate the epoch
  if gap > MaxEpochGap:
    # message's epoch is too old or too ahead
    # accept messages whose epoch is within +-MaxEpochGap from the current epoch
    warn "invalid message: epoch gap exceeds a threshold", gap = gap,
        payload = string.fromBytes(msg.payload)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_epoch"])
    return MessageValidationResult.Invalid

  if not rlnPeer.validateRoot(proof.merkleRoot):
    debug "invalid message: provided root does not belong to acceptable window of roots", provided=proof.merkleRoot, validRoots=rlnPeer.validMerkleRoots.mapIt(it.inHex())
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_root"])
    return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = msg.contentTopic.toBytes
    input = concat(msg.payload, contentTopicBytes)

  waku_rln_proof_verification_total.inc()
  waku_rln_proof_verification_duration_seconds.nanosecondTime:
    let proofVerificationRes = rlnPeer.rlnInstance.proofVerify(input, proof)

  if proofVerificationRes.isErr():
    waku_rln_errors_total.inc(labelValues=["proof_verification"])
    warn "invalid message: proof verification failed", payload = string.fromBytes(msg.payload)
    return MessageValidationResult.Invalid
  if not proofVerificationRes.value():
    # invalid proof
    debug "invalid message: invalid proof", payload = string.fromBytes(msg.payload)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let hasDup = rlnPeer.hasDuplicate(msg)
  if hasDup.isErr():
    waku_rln_errors_total.inc(labelValues=["duplicate_check"])
  elif hasDup.value == true:
    debug "invalid message: message is spam", payload = string.fromBytes(msg.payload)
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  # insert the message to the log
  # the result of `updateLog` is discarded because message insertion is guaranteed by the implementation i.e.,
  # it will never error out
  discard rlnPeer.updateLog(msg)
  debug "message is valid", payload = string.fromBytes(msg.payload)
  let rootIndex = rlnPeer.validMerkleRoots.find(proof.merkleRoot)
  waku_rln_valid_messages_total.observe(rootIndex.toFloat())
  return MessageValidationResult.Valid

proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence
  let
    contentTopicBytes = wakumessage.contentTopic.toBytes
    output = concat(wakumessage.payload, contentTopicBytes)
  return output

proc appendRLNProof*(rlnPeer: WakuRLNRelay, msg: var WakuMessage,
    senderEpochTime: float64): bool =
  ## returns true if it can create and append a `RateLimitProof` to the supplied `msg`
  ## returns false otherwise
  ## `senderEpochTime` indicates the number of seconds passed since Unix epoch. The fractional part holds sub-seconds.
  ## The `epoch` field of `RateLimitProof` is derived from the provided `senderEpochTime` (using `calcEpoch()`)

  let input = msg.toRLNSignal()

  var proof: RateLimitProofResult = proofGen(rlnInstance = rlnPeer.rlnInstance, data = input,
                     memKeys = rlnPeer.identityCredential,
                     memIndex = rlnPeer.membershipIndex,
                     epoch = calcEpoch(senderEpochTime))

  if proof.isErr():
    return false

  msg.proof = proof.value.encode().buffer
  return true

proc addAll*(wakuRlnRelay: WakuRLNRelay, list: seq[IDCommitment]): RlnRelayResult[void] =
  # add members to the Merkle tree of the  `rlnInstance`
  ## Returns an error if it cannot add any member to the Merkle tree
  let membersAdded = wakuRlnRelay.insertMembers(0, list)
  if not membersAdded.isOk():
    return err("failed to add members to the Merkle tree")
  return ok()

proc generateGroupUpdateHandler(rlnPeer: WakuRLNRelay): GroupUpdateHandler =
  ## assuming all the members arrive in order
  ## TODO: check the index and the pubkey depending on
  ## the group update operation
  var handler: GroupUpdateHandler
  handler = proc(blockNumber: BlockNumber, members: seq[MembershipTuple]): RlnRelayResult[void] =
    let startingIndex = members[0].index
    debug "starting index", startingIndex = startingIndex, members = members.mapIt(it.idComm.inHex())
    let isSuccessful = rlnPeer.insertMembers(startingIndex, members.mapIt(it.idComm))
    if isSuccessful.isErr():
      return err("failed to add new members to the Merkle tree")
    else:
      debug "new members added to the Merkle tree", pubkeys=members.mapIt(it.idComm.inHex()) , startingIndex=startingIndex
      debug "acceptable window", validRoots=rlnPeer.validMerkleRoots.mapIt(it.inHex())
      let lastIndex = members[0].index + members.len.uint - 1
      let indexGap = startingIndex - rlnPeer.lastSeenMembershipIndex
      if not (toSeq(startingIndex..lastIndex) == members.mapIt(it.index)):
        return err("the indexes of the new members are not in order")
      if indexGap != 1.uint:
        warn "membership index gap, may have lost connection", lastIndex, currIndex=rlnPeer.lastSeenMembershipIndex, indexGap = indexGap
      rlnPeer.lastSeenMembershipIndex = lastIndex
      rlnPeer.lastProcessedBlock = blockNumber
      debug "last processed block", blockNumber = blockNumber
      return ok()
  return handler

proc parse*(event: type MemberRegistered,
            log: JsonNode): RlnRelayResult[MembershipTuple] =
  ## parses the `data` parameter of the `MemberRegistered` event `log`
  ## returns an error if it cannot parse the `data` parameter
  var pubkey: UInt256
  var index: UInt256
  var data: string
  # Remove the 0x prefix
  try:
    data = strip0xPrefix(log["data"].getStr())
  except CatchableError:
    return err("failed to parse the data field of the MemberRegistered event: " & getCurrentExceptionMsg())
  var offset = 0
  try:
    # Parse the pubkey
    offset += decode(data, offset, pubkey)
    # Parse the index
    offset += decode(data, offset, index)
    return ok((index: index.toMembershipIndex(),
               idComm: pubkey.toIDCommitment()))
  except:
    return err("failed to parse the data field of the MemberRegistered event")

type BlockTable = OrderedTable[BlockNumber, seq[MembershipTuple]]
proc getHistoricalEvents*(ethClientUri: string,
                          contractAddress: Address,
                          fromBlock: string = "0x0",
                          toBlock: string = "latest"): Future[RlnRelayResult[BlockTable]] {.async, gcsafe.} =
  ## `ethClientUri` is the URI of the Ethereum client
  ## `contractAddress` is the address of the contract
  ## `fromBlock` is the block number from which the events are fetched
  ## `toBlock` is the block number to which the events are fetched
  ## returns a table that maps block numbers to the list of members registered in that block
  ## returns an error if it cannot retrieve the historical events
  let web3 = await newWeb3(ethClientUri)
  let contract = web3.contractSender(MembershipContract, contractAddress)
  # Get the historical events, and insert memberships into the tree
  let historicalEvents = await contract.getJsonLogs(MemberRegistered,
                                                    fromBlock=some(fromBlock.blockId()),
                                                    toBlock=some(toBlock.blockId()))
  # Create a table that maps block numbers to the list of members registered in that block
  var blockTable = OrderedTable[BlockNumber, seq[MembershipTuple]]()
  for log in historicalEvents:
    # batch according to log.blockNumber
    let blockNumber = parseHexInt(log["blockNumber"].getStr()).uint
    let parsedEventRes = parse(MemberRegistered, log)

    if parsedEventRes.isErr():
      error "failed to parse the MemberRegistered event", error=parsedEventRes.error()
      return err("failed to parse the MemberRegistered event")
    let parsedEvent = parsedEventRes.get()
    # Add the parsed event to the table
    if blockTable.hasKey(blockNumber):
      blockTable[blockNumber].add(parsedEvent)
    else:
      blockTable[blockNumber] = @[parsedEvent]
  return ok(blockTable)

proc subscribeToGroupEvents*(ethClientUri: string,
                            ethAccountAddress: Option[Address] = none(Address),
                            contractAddress: Address,
                            blockNumber: string = "0x0",
                            handler: GroupUpdateHandler) {.async, gcsafe.} =
  ## connects to the eth client whose URI is supplied as `ethClientUri`
  ## subscribes to the `MemberRegistered` event emitted from the `MembershipContract` which is available on the supplied `contractAddress`
  ## it collects all the events starting from the given `blockNumber`
  ## for every received block, it calls the `handler`
  let web3 = await newWeb3(ethClientUri)
  let contract = web3.contractSender(MembershipContract, contractAddress)

  let blockTableRes = await getHistoricalEvents(ethClientUri,
                                                contractAddress,
                                                fromBlock=blockNumber)
  if blockTableRes.isErr():
    error "failed to retrieve historical events", error=blockTableRes.error
    return
  let blockTable = blockTableRes.get()
  # Update MT by batch
  for blockNumber, members in blockTable.pairs():
    debug "updating the Merkle tree", blockNumber=blockNumber, members=members
    let res = handler(blockNumber, members)
    if res.isErr():
      error "failed to update the Merkle tree", error=res.error

  # We don't need the block table after this point
  discard blockTable

  var latestBlock: BlockNumber
  let handleLog = proc(blockHeader: BlockHeader) {.async, gcsafe.} =
    try:
      let membershipRegistrationLogs = await contract.getJsonLogs(MemberRegistered,
                                                          blockHash = some(blockheader.hash))
      if membershipRegistrationLogs.len == 0:
        return
      var members: seq[MembershipTuple]
      for log in membershipRegistrationLogs:
        let parsedEventRes = parse(MemberRegistered, log)
        if parsedEventRes.isErr():
          fatal "failed to parse the MemberRegistered event", error=parsedEventRes.error()
          return
        let parsedEvent = parsedEventRes.get()
        members.add(parsedEvent)
      let res = handler(blockHeader.number.uint, members)
      if res.isErr():
        error "failed to update the Merkle tree", error=res.error
    except CatchableError:
      warn "failed to get logs", error=getCurrentExceptionMsg()
      return
  let newHeadCallback = proc (blockheader: BlockHeader) {.gcsafe.} =
    latestBlock = blockheader.number.uint
    debug "block received", blockNumber = latestBlock
    # get logs from the last block
    try:
      asyncSpawn handleLog(blockHeader)
    except CatchableError:
      warn "failed to handle log: ", error=getCurrentExceptionMsg()

  let newHeadErrorHandler = proc (err: CatchableError) {.gcsafe.} =
    error "Error from subscription: ", err=err.msg
  discard await web3.subscribeForBlockHeaders(newHeadCallback, newHeadErrorHandler)

  web3.onDisconnect = proc() =
    debug "connection to ethereum node dropped", lastBlock = latestBlock

proc handleGroupUpdates*(rlnPeer: WakuRLNRelay) {.async, gcsafe.} =
  ## generates the groupUpdateHandler which is called when a new member is registered,
  ## and has the WakuRLNRelay instance as a closure
  let handler = generateGroupUpdateHandler(rlnPeer)
  await subscribeToGroupEvents(ethClientUri = rlnPeer.ethClientAddress,
                               ethAccountAddress = rlnPeer.ethAccountAddress,
                               contractAddress = rlnPeer.membershipContractAddress,
                               handler = handler)

proc addRLNRelayValidator*(wakuRlnRelay: WakuRLNRelay,
                           wakuRelay: WakuRelay,
                           pubsubTopic: PubsubTopic,
                           contentTopic: ContentTopic,
                           spamHandler: Option[SpamHandler] = none(SpamHandler)) =
  ## this procedure is a thin wrapper for the pubsub addValidator method
  ## it sets a validator for the waku messages published on the supplied pubsubTopic and contentTopic
  ## if contentTopic is empty, then validation takes place for All the messages published on the given pubsubTopic
  ## the message validation logic is according to https://rfc.vac.dev/spec/17/
  proc validator(topic: string, message: messages.Message): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    let decodeRes = WakuMessage.decode(message.data)
    if decodeRes.isOk():
      let
        wakumessage = decodeRes.value
        payload = string.fromBytes(wakumessage.payload)

      # check the contentTopic
      if (wakumessage.contentTopic != "") and (contentTopic != "") and (wakumessage.contentTopic != contentTopic):
        trace "content topic did not match:", contentTopic=wakumessage.contentTopic, payload=payload
        return pubsub.ValidationResult.Accept


      let decodeRes = RateLimitProof.init(wakumessage.proof)
      if decodeRes.isErr():
        return pubsub.ValidationResult.Reject

      let msgProof = decodeRes.get()

      # validate the message
      let
        validationRes = wakuRlnRelay.validateMessage(wakumessage)
        proof = toHex(msgProof.proof)
        epoch = fromEpoch(msgProof.epoch)
        root = inHex(msgProof.merkleRoot)
        shareX = inHex(msgProof.shareX)
        shareY = inHex(msgProof.shareY)
        nullifier = inHex(msgProof.nullifier)
      case validationRes:
        of Valid:
          debug "message validity is verified, relaying:",  contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity is verified, relaying:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Accept
        of Invalid:
          debug "message validity could not be verified, discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity could not be verified, discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Reject
        of Spam:
          debug "A spam message is found! yay! discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "A spam message is found! yay! discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          if spamHandler.isSome():
            let handler = spamHandler.get()
            handler(wakumessage)
          return pubsub.ValidationResult.Reject
  # set a validator for the supplied pubsubTopic
  let pb = PubSub(wakuRelay)
  pb.addValidator(pubsubTopic, validator)

proc mountRlnRelayStatic*(wakuRelay: WakuRelay,
                          group: seq[IDCommitment],
                          memIdCredential: IdentityCredential,
                          memIndex: MembershipIndex,
                          pubsubTopic: PubsubTopic,
                          contentTopic: ContentTopic,
                          spamHandler: Option[SpamHandler] = none(SpamHandler)): RlnRelayResult[WakuRlnRelay] =
  # Returns RlnRelayResult[void] to indicate the success of the call

  debug "mounting rln-relay in off-chain/static mode"
  # check the peer's index and the inclusion of user's identity commitment in the group
  if not memIdCredential.idCommitment  == group[int(memIndex)]:
    return err("The peer's index is not consistent with the group")

  # create an RLN instance
  let rlnInstance = createRLNInstance()
  if rlnInstance.isErr():
    return err("RLN instance creation failed")
  let rln = rlnInstance.get()

  # create the WakuRLNRelay
  let rlnPeer = WakuRLNRelay(identityCredential: memIdCredential,
    membershipIndex: memIndex,
    rlnInstance: rln,
    pubsubTopic: pubsubTopic,
    contentTopic: contentTopic)

  # add members to the Merkle tree
  let membersAdded = rlnPeer.insertMembers(0, group)
  if membersAdded.isErr():
    return err("member addition to the Merkle tree failed: " & membersAdded.error)

  # adds a topic validator for the supplied pubsub topic at the relay protocol
  # messages published on this pubsub topic will be relayed upon a successful validation, otherwise they will be dropped
  # the topic validator checks for the correct non-spamming proof of the message
  rlnPeer.addRLNRelayValidator(wakuRelay, pubsubTopic, contentTopic, spamHandler)
  debug "rln relay topic validator is mounted successfully", pubsubTopic=pubsubTopic, contentTopic=contentTopic

  return ok(rlnPeer)

proc mountRlnRelayDynamic*(wakuRelay: WakuRelay,
                           ethClientAddr: string = "",
                           ethAccountAddress: Option[web3.Address] = none(web3.Address),
                           ethAccountPrivKeyOpt: Option[keys.PrivateKey],
                           memContractAddr:  web3.Address,
                           memIdCredential: Option[IdentityCredential] = none(IdentityCredential),
                           memIndex: Option[MembershipIndex] = none(MembershipIndex),
                           pubsubTopic: PubsubTopic,
                           contentTopic: ContentTopic,
                           spamHandler: Option[SpamHandler] = none(SpamHandler),
                           registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)) : Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  debug "mounting rln-relay in on-chain/dynamic mode"
  # create an RLN instance
  let rlnInstance = createRLNInstance()

  if rlnInstance.isErr():
    return err("RLN instance creation failed.")
  let rln = rlnInstance.get()

  # prepare rln membership credential
  var
    idCredential: IdentityCredential
    rlnIndex: MembershipIndex
  if memIdCredential.isNone: # no rln credentials provided
    if ethAccountPrivKeyOpt.isSome: # if an ethereum private key is supplied, then create rln credentials and register to the membership contract
      trace "no rln-relay key is provided, generating one"
      let idCredentialRes = rln.membershipKeyGen()
      if idCredentialRes.isErr():
        error "failed to generate rln-relay identity credential"
        return err("failed to generate rln-relay identity credential: " & idCredentialRes.error())
      idCredential = idCredentialRes.value()
      # register the rln-relay peer to the membership contract
      waku_rln_registration_duration_seconds.nanosecondTime:
        let regIndexRes = await register(idComm = idCredential.idCommitment,
                                         ethAccountAddress = ethAccountAddress,
                                         ethAccountPrivKey = ethAccountPrivKeyOpt.get(),
                                         ethClientAddress = ethClientAddr,
                                         membershipContractAddress = memContractAddr,
                                         registrationHandler = registrationHandler)
      # check whether registration is done
      if regIndexRes.isErr():
        debug "membership registration failed", err=regIndexRes.error()
        return err("membership registration failed: " & regIndexRes.error())
      rlnIndex = regIndexRes.value
      debug "peer is successfully registered into the membership contract"
    else: # if no eth private key is available, skip registration
      debug "running waku-rln-relay in relay-only mode"
  else:
    debug "Peer is already registered to the membership contract"
    idCredential = memIdCredential.get()
    rlnIndex = memIndex.get()

  # create the WakuRLNRelay
  var rlnPeer = WakuRLNRelay(identityCredential: idCredential,
    membershipIndex: rlnIndex,
    membershipContractAddress: memContractAddr,
    ethClientAddress: ethClientAddr,
    ethAccountAddress: ethAccountAddress,
    ethAccountPrivateKey: ethAccountPrivKeyOpt,
    rlnInstance: rln,
    pubsubTopic: pubsubTopic,
    contentTopic: contentTopic)

  asyncSpawn rlnPeer.handleGroupUpdates()
  debug "dynamic group management is started"
  # adds a topic validator for the supplied pubsub topic at the relay protocol
  # messages published on this pubsub topic will be relayed upon a successful validation, otherwise they will be dropped
  # the topic validator checks for the correct non-spamming proof of the message
  rlnPeer.addRLNRelayValidator(wakuRelay, pubsubTopic, contentTopic, spamHandler)
  debug "rln relay topic validator is mounted successfully", pubsubTopic=pubsubTopic, contentTopic=contentTopic

  return ok(rlnPeer)

proc writeRlnCredentials*(path: string,
                          credentials: RlnMembershipCredentials,
                          password: string): RlnRelayResult[void] =
  # Returns RlnRelayResult[void], which indicates the success of the call
  info "Storing RLN credentials"
  var jsonString: string
  jsonString.toUgly(%credentials)
  let keyfile = createKeyFileJson(toBytes(jsonString), password)
  if keyfile.isErr():
    return err("Error while creating keyfile for RLN credentials")
  if saveKeyFile(path, keyfile.get()).isErr():
    return err("Error while saving keyfile for RLN credentials")
  return ok()

# Attempts decryptions of all keyfiles with the provided password.
# If one or more credentials are successfully decrypted, the max(min(index,number_decrypted),0)-th is returned.
proc readRlnCredentials*(path: string,
                         password: string,
                         index: int = 0): RlnRelayResult[Option[RlnMembershipCredentials]] =
  # Returns RlnRelayResult[Option[RlnMembershipCredentials]], which indicates the success of the call
  info "Reading RLN credentials"
  # With regards to printing the keys, it is purely for debugging purposes so that the user becomes explicitly aware of the current keys in use when nwaku is started.
  # Note that this is only until the RLN contract being used is the one deployed on Goerli testnet.
  # These prints need to omitted once RLN contract is deployed on Ethereum mainnet and using valuable funds for staking.
  waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:

    try:
      var decodedKeyfiles = loadKeyFiles(path, password)

      if decodedKeyfiles.isOk():
        var decodedRlnCredentials = decodedKeyfiles.get()
        debug "Successfully decrypted keyfiles for the provided password", numberKeyfilesDecrypted=decodedRlnCredentials.len
        # We should return the index-th decrypted credential, but we ensure to not overflow
        let credentialIndex = max(min(index, decodedRlnCredentials.len - 1), 0)
        debug "Picking credential with (adjusted) index", inputIndex=index, adjustedIndex=credentialIndex
        let jsonObject = parseJson(string.fromBytes(decodedRlnCredentials[credentialIndex].get()))
        let deserializedRlnCredentials = to(jsonObject, RlnMembershipCredentials)
        debug "Deserialized RLN credentials", rlnCredentials=deserializedRlnCredentials
        return ok(some(deserializedRlnCredentials))
      else:
        debug "Unable to decrypt RLN credentials with provided password. ", error=decodedKeyfiles.error
        return ok(none(RlnMembershipCredentials))
    except:
      return err("Error while loading keyfile for RLN credentials at " & path)

proc mount(wakuRelay: WakuRelay,
           conf: WakuRlnConfig,
           spamHandler: Option[SpamHandler] = none(SpamHandler),
           registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =

  if not conf.rlnRelayDynamic:
    info " setting up waku-rln-relay in off-chain mode... "
    # set up rln relay inputs
    let staticSetupRes = rlnRelayStaticSetUp(MembershipIndex(conf.rlnRelayMembershipIndex))
    if staticSetupRes.isErr():
      return err("rln relay static setup failed: " & staticSetupRes.error())
    let (groupOpt, idCredentialOpt, memIndexOpt) = staticSetupRes.get()
    if memIndexOpt.isNone():
      error "failed to mount WakuRLNRelay"
      return err("failed to mount WakuRLNRelay")
    else:
      # mount rlnrelay in off-chain mode with a static group of users
      let mountRes = mountRlnRelayStatic(wakuRelay,
                                         group = groupOpt.get(),
                                         memIdCredential = idCredentialOpt.get(),
                                         memIndex = memIndexOpt.get(),
                                         pubsubTopic = conf.rlnRelayPubsubTopic,
                                         contentTopic = conf.rlnRelayContentTopic,
                                         spamHandler = spamHandler)

      if mountRes.isErr():
        return err("Failed to mount WakuRLNRelay: " & mountRes.error())

      let rlnRelay = mountRes.get()

      info "membership id key", idkey=idCredentialOpt.get().idSecretHash.inHex()
      info "membership id commitment key", idCommitmentkey=idCredentialOpt.get().idCommitment.inHex()

      # check the correct construction of the tree by comparing the calculated root against the expected root
      # no error should happen as it is already captured in the unit tests
      # TODO have added this check to account for unseen corner cases, will remove it later
      let
        rootRes = rlnRelay.rlnInstance.getMerkleRoot()
        expectedRoot = StaticGroupMerkleRoot

      if rootRes.isErr():
        return err(rootRes.error())

      let root = rootRes.value()

      if root.inHex() != expectedRoot:
        error "root mismatch: something went wrong not in Merkle tree construction"
      debug "the calculated root", root
      info "WakuRLNRelay is mounted successfully", pubsubtopic=conf.rlnRelayPubsubTopic, contentTopic=conf.rlnRelayContentTopic
      return ok(rlnRelay)
  else: # mount the rln relay protocol in the on-chain/dynamic mode
    debug "setting up waku-rln-relay in on-chain mode... "

    debug "on-chain setup parameters", contractAddress=conf.rlnRelayEthContractAddress
    # read related inputs to run rln-relay in on-chain mode and do type conversion when needed
    let
      ethClientAddr = conf.rlnRelayEthClientAddress

    var ethMemContractAddress: web3.Address
    try:
      ethMemContractAddress = web3.fromHex(web3.Address, conf.rlnRelayEthContractAddress)
    except ValueError as err:
      return err("invalid eth contract address: " & err.msg)
    var ethAccountPrivKeyOpt = none(keys.PrivateKey)
    var ethAccountAddressOpt = none(Address)
    var credentials = none(RlnMembershipCredentials)
    var rlnRelayRes: RlnRelayResult[WakuRlnRelay]
    var rlnRelayCredPath: string
    var persistCredentials: bool = false

    if conf.rlnRelayEthAccountPrivateKey != "":
      ethAccountPrivKeyOpt = some(keys.PrivateKey(SkSecretKey.fromHex(conf.rlnRelayEthAccountPrivateKey).value))

    if conf.rlnRelayEthAccountAddress != "":
      var ethAccountAddress: web3.Address
      try:
        ethAccountAddress = web3.fromHex(web3.Address, conf.rlnRelayEthAccountAddress)
      except ValueError as err:
        return err("invalid eth account address: " & err.msg)
      ethAccountAddressOpt = some(ethAccountAddress)

    # if the rlnRelayCredPath config option is non-empty, then rln-relay credentials should be persisted
    # if the path does not contain any credential file, then a new set is generated and pesisted in the same path
    # if there is a credential file, then no new credentials are generated, instead the content of the file is read and used to mount rln-relay
    if conf.rlnRelayCredPath != "":

      rlnRelayCredPath = joinPath(conf.rlnRelayCredPath, RlnCredentialsFilename)
      debug "rln-relay credential path", rlnRelayCredPath

      # check if there is an rln-relay credential file in the supplied path
      if fileExists(rlnRelayCredPath):

        info "A RLN credential file exists in provided path", path=rlnRelayCredPath

        # retrieve rln-relay credential
        let readCredentialsRes = readRlnCredentials(rlnRelayCredPath, conf.rlnRelayCredentialsPassword)

        if readCredentialsRes.isErr():
          return err("RLN credentials cannot be read: " & readCredentialsRes.error())

        credentials = readCredentialsRes.get()

      else: # there is no credential file available in the supplied path
        # mount the rln-relay protocol leaving rln-relay credentials arguments unassigned
        # this infroms mountRlnRelayDynamic proc that new credentials should be generated and registered to the membership contract
        info "no rln credential is provided"

      if credentials.isSome():
        # mount rln-relay in on-chain mode, with credentials that were read or generated
        rlnRelayRes = await mountRlnRelayDynamic(wakuRelay,
                                                 memContractAddr = ethMemContractAddress,
                                                 ethClientAddr = ethClientAddr,
                                                 ethAccountAddress = ethAccountAddressOpt,
                                                 ethAccountPrivKeyOpt = ethAccountPrivKeyOpt,
                                                 pubsubTopic = conf.rlnRelayPubsubTopic,
                                                 contentTopic = conf.rlnRelayContentTopic,
                                                 spamHandler = spamHandler,
                                                 registrationHandler = registrationHandler,
                                                 memIdCredential = some(credentials.get().identityCredential),
                                                 memIndex = some(credentials.get().rlnIndex))
      else:
        # mount rln-relay in on-chain mode, with the provided private key
        rlnRelayRes = await mountRlnRelayDynamic(wakuRelay,
                                                 memContractAddr = ethMemContractAddress,
                                                 ethClientAddr = ethClientAddr,
                                                 ethAccountAddress = ethAccountAddressOpt,
                                                 ethAccountPrivKeyOpt = ethAccountPrivKeyOpt,
                                                 pubsubTopic = conf.rlnRelayPubsubTopic,
                                                 contentTopic = conf.rlnRelayContentTopic,
                                                 spamHandler = spamHandler,
                                                 registrationHandler = registrationHandler)

        persistCredentials = true

    else:
      # do not persist or use a persisted rln-relay credential
      # a new credential will be generated during the mount process but will not be persisted
      info "no need to persist or use a persisted rln-relay credential"
      rlnRelayRes = await mountRlnRelayDynamic(wakuRelay,
                                               memContractAddr = ethMemContractAddress,
                                               ethClientAddr = ethClientAddr,
                                               ethAccountAddress = ethAccountAddressOpt,
                                               ethAccountPrivKeyOpt = ethAccountPrivKeyOpt,
                                               pubsubTopic = conf.rlnRelayPubsubTopic,
                                               contentTopic = conf.rlnRelayContentTopic,
                                               spamHandler = spamHandler,
                                               registrationHandler = registrationHandler)

    if rlnRelayRes.isErr():
      return err("dynamic rln-relay could not be mounted: " & rlnRelayRes.error())
    let wakuRlnRelay = rlnRelayRes.get()
    if persistCredentials:
      # persist rln credential
      credentials = some(RlnMembershipCredentials(rlnIndex: wakuRlnRelay.membershipIndex,
                                                  identityCredential: wakuRlnRelay.identityCredential))
      if writeRlnCredentials(rlnRelayCredPath, credentials.get(), conf.rlnRelayCredentialsPassword).isErr():
        return err("error in storing rln credentials")
    return ok(wakuRlnRelay)

proc new*(T: type WakuRlnRelay,
           wakuRelay: WakuRelay,
           conf: WakuRlnConfig,
           spamHandler: Option[SpamHandler] = none(SpamHandler),
           registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.

  # check whether inputs are provided
  # relay protocol is the prerequisite of rln-relay
  if wakuRelay.isNil():
    return err("WakuRelay protocol is not mounted")
  # check whether the pubsub topic is supported at the relay level
  if conf.rlnRelayPubsubTopic notin wakuRelay.defaultPubsubTopics:
    return err("The relay protocol does not support the configured pubsub topic")

  debug "rln-relay input validation passed"
  waku_rln_relay_mounting_duration_seconds.nanosecondTime:
    let rlnRelayRes = await mount(
      wakuRelay,
      conf,
      spamHandler,
      registrationHandler
    )
  return rlnRelayRes
