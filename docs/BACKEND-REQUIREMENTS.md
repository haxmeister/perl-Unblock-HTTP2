# Backend requirements

Unblock::HTTP2 uses Net::HTTP2::nghttp2 as its libnghttp2 binding.

The byte engine should not duplicate nghttp2 frame parsing merely to work
around missing Perl binding accessors. This file records backend capabilities
that are needed for a complete Unblock HTTP/2 engine but are not exposed by
Net::HTTP2::nghttp2 0.011.

## Remote SETTINGS

Unblock can advertise local SETTINGS, including
SETTINGS_ENABLE_CONNECT_PROTOCOL, but the binding does not expose the peer's
effective SETTINGS values.

This prevents Unblock from enforcing two important rules itself:

- an Extended CONNECT request must not be sent until the peer has advertised
  SETTINGS_ENABLE_CONNECT_PROTOCOL = 1
- the client should use the peer's SETTINGS_MAX_CONCURRENT_STREAMS rather than
  only a local configured stream limit

Desired backend capability:

    $session->get_remote_setting($setting_id)

or an equivalent decoded remote-settings API.

The underlying libnghttp2 API already has remote-settings state; Unblock should
consume that state rather than parse SETTINGS frames independently.

## Non-final HEADERS

Uniform::HTTP can represent informational responses such as 100 and 103, and
the Unblock client can receive them.

Net::HTTP2::nghttp2 0.011 does not expose a generic non-final HEADERS
submission operation suitable for sending an informational response before the
final response.

Desired backend capability is a wrapper around the appropriate
nghttp2_submit_headers behavior, allowing Unblock to send one or more 1xx
responses without closing the response half of the stream.

The public Unblock API for server informational responses should be added only
after this primitive is available.

## GOAWAY details

The frame callback currently identifies a GOAWAY frame but does not expose its:

- last stream ID
- HTTP/2 error code
- optional debug data

Unblock can therefore enter draining state, but it cannot yet expose the
complete peer GOAWAY information to a higher transaction/pooling layer.

Desired backend behavior is to include those fields in the frame callback data.

Retry policy remains outside Unblock, but callers need the GOAWAY boundary to
decide which operations might be retried.

## Server push

Unblock currently advertises SETTINGS_ENABLE_PUSH = 0 from the client and does
not expose a public push API.

A complete optional HTTP/2 push implementation would require the binding to
expose push-promise submission and the relevant pushed-stream metadata.

Until then, disabling push is preferable to advertising a capability the
portable engine cannot represent.

## Windows XS build

Alien::nghttp2 0.003 successfully builds libnghttp2 on Strawberry Perl under
the Unblock Windows CI job.

Net::HTTP2::nghttp2 0.011 then fails while compiling its XS. The observed
failure is in perl_send_callback():

    PERL_NO_GET_CONTEXT is defined
    realloc expands to Perl's allocator macro
    the callback has no dTHX declaration
    Strawberry's multiplicity build therefore has no my_perl context

The compiler reports my_perl as undeclared at the realloc call.

This is a binding build issue, not an Unblock or libnghttp2 portability issue.
Unblock should keep the Windows CI leg so the backend fix can be verified as
soon as a corrected backend release is available.
