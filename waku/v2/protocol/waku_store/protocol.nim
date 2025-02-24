## Waku Store protocol for historical messaging support.
## See spec for more details:
## https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-store.md
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  bearssl/rand,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  metrics
import
  ../../node/peer_manager/peer_manager,
  ../../utils/time,
  ../waku_message,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics


logScope:
  topics = "waku store"


const
  MaxMessageTimestampVariance* = getNanoSecondTime(20) # 20 seconds maximum allowable sender timestamp "drift"


type HistoryQueryHandler* = proc(req: HistoryQuery): HistoryResult {.gcsafe.}

type
  WakuStore* = ref object of LPProtocol
    peerManager: PeerManager
    rng: ref rand.HmacDrbgContext
    queryHandler: HistoryQueryHandler

## Protocol

proc initProtocolHandler(ws: WakuStore) =

  proc handler(conn: Connection, proto: string) {.async.} =
    let buf = await conn.readLp(MaxRpcSize.int)

    let decodeRes = HistoryRPC.decode(buf)
    if decodeRes.isErr():
      error "failed to decode rpc", peerId= $conn.peerId
      waku_store_errors.inc(labelValues = [decodeRpcFailure])
      # TODO: Return (BAD_REQUEST, cause: "decode rpc failed")
      return


    let reqRpc = decodeRes.value

    if reqRpc.query.isNone():
      error "empty query rpc", peerId= $conn.peerId, requestId=reqRpc.requestId
      waku_store_errors.inc(labelValues = [emptyRpcQueryFailure])
      # TODO: Return (BAD_REQUEST, cause: "empty query")
      return

    let
      requestId = reqRpc.requestId
      request = reqRpc.query.get().toAPI()

    info "received history query", peerId=conn.peerId, requestId=requestId, query=request
    waku_store_queries.inc()

    let responseRes = ws.queryHandler(request)

    if responseRes.isErr():
      error "history query failed", peerId= $conn.peerId, requestId=requestId, error=responseRes.error

      let response = responseRes.toRPC()
      let rpc = HistoryRPC(requestId: requestId, response: some(response))
      await conn.writeLp(rpc.encode().buffer)
      return


    let response = responseRes.toRPC()

    info "sending history response", peerId=conn.peerId, requestId=requestId, messages=response.messages.len

    let rpc = HistoryRPC(requestId: requestId, response: some(response))
    await conn.writeLp(rpc.encode().buffer)

  ws.handler = handler
  ws.codec = WakuStoreCodec


proc new*(T: type WakuStore,
          peerManager: PeerManager,
          rng: ref rand.HmacDrbgContext,
          queryHandler: HistoryQueryHandler): T =

  # Raise a defect if history query handler is nil
  if queryHandler.isNil():
    raise newException(NilAccessDefect, "history query handler is nil")

  let ws = WakuStore(
    rng: rng,
    peerManager: peerManager,
    queryHandler: queryHandler
  )
  ws.initProtocolHandler()
  ws
