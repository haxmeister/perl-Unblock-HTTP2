# Unblock::HTTP2 feature completeness

This document defines what Unblock::HTTP2 considers a complete HTTP/2 protocol
engine.

The goal is not to implement every historical or optional extension ever
registered for HTTP/2. The goal is a complete modern HTTP/2 byte engine that
can be embedded into any transport or event loop without taking over transport
policy.

## Core HTTP/2

Implemented:

- client connection preface and HTTP/2 session startup
- SETTINGS send, receive, validation, ACK tracking, and inspection
- HEADERS and CONTINUATION processing through libnghttp2
- HPACK compression and decompression through libnghttp2
- DATA send and receive
- independent multiplexed streams
- stream concurrency limits
- stream half-close behavior
- RST_STREAM send and receive
- standard HTTP/2 error codes and reset attribution
- connection and stream flow control
- application-controlled receive consumption
- outbound body backpressure and drain notification
- PING send, receive, and ACK observation
- GOAWAY send, receive, graceful drain, explicit error codes, and debug data
- fatal session failure closure and close-reason inspection
- invalid-frame observation while retaining libnghttp2 protocol handling
- required handling of unknown frame types as ignorable extensions

## HTTP semantics

Implemented:

- Uniform::HTTP::Request and Uniform::HTTP::Response messages
- HTTP/2 pseudo-header mapping
- lowercase field handling
- rejection of connection-specific HTTP/1 fields
- TE limited to trailers
- duplicate and ordered field preservation
- informational 1xx responses
- response and request trailers
- ordinary CONNECT
- Extended CONNECT and SETTINGS_ENABLE_CONNECT_PROTOCOL
- symmetric validation of received and generated pseudo-header sets
- configurable header-list limits

## Modern prioritization

Implemented using RFC 9218:

- SETTINGS_NO_RFC7540_PRIORITIES
- ordinary Priority HTTP fields
- PRIORITY_UPDATE from client streams
- server observation of priority updates
- libnghttp2 scheduling integration

The deprecated RFC 7540 dependency-tree PRIORITY model is intentionally not
part of the public API.

## Deliberate exclusions

These are not missing core work.

### Server push

PUSH_PROMISE and a public server-push API are intentionally omitted.
Clients advertise SETTINGS_ENABLE_PUSH = 0. Server push has poor modern
deployment value and would add a second request-creation model to the API.

### Transport and negotiation

Unblock::HTTP2 does not own:

- sockets
- DNS
- TLS
- ALPN
- event loops
- HTTP/1.1 Upgrade or h2c negotiation
- connection pooling

A host feeds HTTP/2 bytes to input() and drains bytes from output().

### Higher-level HTTP policy

Unblock::HTTP2 does not implement:

- automatic retries
- redirects
- cookies
- authentication policy
- proxy selection
- caching

The engine exposes protocol facts such as GOAWAY boundaries and stream reset
codes so a higher layer can make those decisions correctly.

### Optional extension frames

Extensions such as ORIGIN and ALTSVC are not part of the core completeness
target. Unsupported extension frame types remain safe because HTTP/2 requires
unknown frame types to be ignored.

### Tunnel protocol semantics

Extended CONNECT is supported generically. The semantics layered inside a
successful tunnel, such as WebSocket, CONNECT-UDP, or another protocol, belong
to their own protocol layer.

## Completeness status

With the items above implemented and covered by the portability test matrix,
Unblock::HTTP2 is considered feature-complete for its intended role as a
modern, event-loop-neutral HTTP/2 protocol engine.

Future work should therefore be treated as one of:

- bug fixes
- interoperability fixes
- performance work
- optional HTTP/2 extensions
- documentation and release work

rather than unfinished core HTTP/2 implementation.
