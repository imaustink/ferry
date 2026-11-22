// The HTTP/2 settings of the socket the kubelet talks CRI over.
//
// gRPC's HTTP/2 flood protection allows a client 200 control frames in 10
// seconds (NIO's own default, which it replaced, was 200 in 30), and the
// kubelet's gRPC client sends a PING each time data arrives while none is
// outstanding -- its BDP estimator, which over a Unix socket never finds a
// window worth growing into and so never stops. A 20-pod burst went past the
// 30-second limit in under 30 s, six times in four soak cycles. NIO answered
// with a GOAWAY that said no call had been processed, so the kubelet sent every
// call in flight again, and the ones it could not resend it failed. Either way
// a pod got a second container beside a first that was already starting, and
// crash-looped on its ports (experiment 38).
//
// The socket is this user's alone and its one client is the kubelet, so the
// limit is set where no real client reaches it. It is not removed: the limiter
// allocates room for the whole count up front.

import GRPCNIOTransportHTTP2

enum CRITransport {
    static let controlFrames = RateLimit(maxCount: 10_000, window: .seconds(1))

    static var config: HTTP2ServerTransport.Posix.Config {
        .defaults { $0.http2.rateLimits.controlFrames = controlFrames }
    }
}
