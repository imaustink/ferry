# grpc-swift-nio-transport 2.9.2, patched

This is [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport)
at tag 2.9.2, Apache 2.0 (see LICENSE and NOTICES.txt). It contains only the
sources and the manifest. The two test targets were dropped from `Package.swift`,
because their sources are not here.

## The one change

`HTTP2ServerTransport.Config.HTTP2.controlFrameRateLimit` is new. It is passed
through to `NIOHTTP2Handler.ConnectionConfiguration.controlFrameRateLimit`, which
NIO exposes and 2.9.2 (and 2.10.0) never set. The default is NIO's own,
200 frames per 30 s, so a caller that does not set it behaves exactly as before.

- `Sources/GRPCNIOTransportCore/Server/HTTP2ServerTransport.swift`: the property
  and its `ControlFrameRateLimit` type.
- `Sources/GRPCNIOTransportCore/Internal/NIOChannelPipeline+GRPC.swift`: passes
  it to NIO in the server pipeline.

## Why

ferry-cri's only client is the kubelet. grpc-go's BDP estimator sends a PING each
time data arrives while no PING is outstanding. Over a Unix socket it never stops,
and under a pod burst it passes 200 in 30 s. NIO then closes the connection as a
flood, with a GOAWAY whose last stream ID is 0, and the kubelet re-sends or fails
every call in flight. See experiments/38-soak/FINDINGS.md.

## The SwiftPM warning

Containerization depends on this package by URL. ferry-cri's path dependency
replaces it for the whole graph, and SwiftPM warns "Conflicting identity for
grpc-swift-nio-transport ... will be escalated to an error in future versions".
A fork at another URL would get the same warning, because identity comes from the
last path component. If a future SwiftPM makes it an error, a mirror
(`swift package config set-mirror`) is the supported way to replace one.

## Leaving this copy

Delete this directory and put the URL dependency back once upstream exposes the
limit.
