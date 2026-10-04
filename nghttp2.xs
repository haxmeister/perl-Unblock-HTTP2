#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <nghttp2/nghttp2.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct unblock_h2_provider unblock_h2_provider;

struct unblock_h2_provider {
    unblock_h2_provider *next;
    unblock_h2_provider *pending_next;
    SV *callback;
    int32_t stream_id;
    int deferred;
    int released;
};

typedef struct {
    nghttp2_session *session;
    SV *cb_begin_headers;
    SV *cb_header;
    SV *cb_frame_recv;
    SV *cb_data_chunk_recv;
    SV *cb_stream_close;
    SV *cb_invalid_frame;
    SV *cb_error;
    SV *callback_error;
    unblock_h2_provider *providers;
    unblock_h2_provider *pending_free;
    int in_session_call;
} unblock_h2_session;

static unblock_h2_session *
session_from_sv(pTHX_ SV *self)
{
    unblock_h2_session *ps;

    if (!SvROK(self)) {
        croak("Unblock::HTTP2::_nghttp2::Session: invalid session object");
    }

    ps = INT2PTR(unblock_h2_session *, SvIV(SvRV(self)));
    if (!ps || !ps->session) {
        croak("Unblock::HTTP2::_nghttp2::Session: session has been destroyed");
    }

    return ps;
}

static void
set_callback_error(pTHX_ unblock_h2_session *ps, const char *prefix)
{
    SV *error;

    if (ps->callback_error) {
        return;
    }

    error = ERRSV;
    if (error && SvTRUE(error)) {
        ps->callback_error = newSVpvf("%s: %s", prefix, SvPV_nolen(error));
    }
    else {
        ps->callback_error = newSVpv(prefix, 0);
    }
}

static void
clear_callback_error(pTHX_ unblock_h2_session *ps)
{
    if (ps->callback_error) {
        SvREFCNT_dec(ps->callback_error);
        ps->callback_error = NULL;
    }
}

static void
croak_callback_error(pTHX_ unblock_h2_session *ps)
{
    SV *error;

    if (!ps->callback_error) {
        return;
    }

    error = ps->callback_error;
    ps->callback_error = NULL;
    sv_2mortal(error);
    croak("%s", SvPV_nolen(error));
}

static SV *
callback_from_hash(pTHX_ HV *callbacks, const char *name, I32 name_len)
{
    SV **svp;

    if (!callbacks) {
        return NULL;
    }

    svp = hv_fetch(callbacks, name, name_len, 0);
    if (!svp || !SvOK(*svp)) {
        return NULL;
    }

    if (!SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVCV) {
        croak("callback %s must be a coderef", name);
    }

    return newSVsv(*svp);
}

static void
load_callbacks(pTHX_ unblock_h2_session *ps, HV *callbacks)
{
    ps->cb_begin_headers = callback_from_hash(aTHX_ callbacks, "on_begin_headers", 16);
    ps->cb_header = callback_from_hash(aTHX_ callbacks, "on_header", 9);
    ps->cb_frame_recv = callback_from_hash(aTHX_ callbacks, "on_frame_recv", 13);
    ps->cb_data_chunk_recv = callback_from_hash(aTHX_ callbacks, "on_data_chunk_recv", 18);
    ps->cb_stream_close = callback_from_hash(aTHX_ callbacks, "on_stream_close", 15);
    ps->cb_invalid_frame = callback_from_hash(aTHX_ callbacks, "on_invalid_frame", 16);
    ps->cb_error = callback_from_hash(aTHX_ callbacks, "on_error", 8);
}

static void
release_callbacks(pTHX_ unblock_h2_session *ps)
{
    if (ps->cb_begin_headers) SvREFCNT_dec(ps->cb_begin_headers);
    if (ps->cb_header) SvREFCNT_dec(ps->cb_header);
    if (ps->cb_frame_recv) SvREFCNT_dec(ps->cb_frame_recv);
    if (ps->cb_data_chunk_recv) SvREFCNT_dec(ps->cb_data_chunk_recv);
    if (ps->cb_stream_close) SvREFCNT_dec(ps->cb_stream_close);
    if (ps->cb_invalid_frame) SvREFCNT_dec(ps->cb_invalid_frame);
    if (ps->cb_error) SvREFCNT_dec(ps->cb_error);
    if (ps->callback_error) SvREFCNT_dec(ps->callback_error);

    ps->cb_begin_headers = NULL;
    ps->cb_header = NULL;
    ps->cb_frame_recv = NULL;
    ps->cb_data_chunk_recv = NULL;
    ps->cb_stream_close = NULL;
    ps->cb_invalid_frame = NULL;
    ps->cb_error = NULL;
    ps->callback_error = NULL;
}

static unblock_h2_provider *
find_provider(unblock_h2_session *ps, int32_t stream_id)
{
    unblock_h2_provider *provider = ps->providers;

    while (provider) {
        if (provider->stream_id == stream_id) {
            return provider;
        }
        provider = provider->next;
    }

    return NULL;
}

static void
free_provider(pTHX_ unblock_h2_provider *provider)
{
    if (provider->callback) {
        SvREFCNT_dec(provider->callback);
    }
    free(provider);
}

static void
drain_pending_free(pTHX_ unblock_h2_session *ps)
{
    unblock_h2_provider *provider = ps->pending_free;

    ps->pending_free = NULL;
    while (provider) {
        unblock_h2_provider *next = provider->pending_next;
        free_provider(aTHX_ provider);
        provider = next;
    }
}

static void
remove_provider(pTHX_ unblock_h2_session *ps, int32_t stream_id)
{
    unblock_h2_provider **link = &ps->providers;

    while (*link) {
        unblock_h2_provider *provider = *link;
        if (provider->stream_id == stream_id) {
            *link = provider->next;
            provider->released = 1;

            if (ps->in_session_call) {
                provider->pending_next = ps->pending_free;
                ps->pending_free = provider;
            }
            else {
                free_provider(aTHX_ provider);
            }
            return;
        }
        link = &provider->next;
    }
}

static void
add_provider(pTHX_ unblock_h2_session *ps, unblock_h2_provider *provider)
{
    if (find_provider(ps, provider->stream_id)) {
        croak("stream %d already has a data provider", (int)provider->stream_id);
    }

    provider->next = ps->providers;
    ps->providers = provider;
}

static nghttp2_nv *
headers_to_nva(pTHX_ AV *headers, size_t *count_out)
{
    I32 last = av_len(headers);
    size_t count = last < 0 ? 0 : (size_t)last + 1;
    nghttp2_nv *nva;
    I32 i;

    *count_out = count;
    if (count == 0) {
        return NULL;
    }

    for (i = 0; i <= last; i++) {
        SV **pair_sv = av_fetch(headers, i, 0);
        AV *pair;
        SV **name_sv;
        SV **value_sv;

        if (!pair_sv || !SvROK(*pair_sv) || SvTYPE(SvRV(*pair_sv)) != SVt_PVAV) {
            croak("header %ld must be a two-element array reference", (long)i);
        }

        pair = (AV *)SvRV(*pair_sv);
        if (av_len(pair) != 1) {
            croak("header %ld must be a two-element array reference", (long)i);
        }

        name_sv = av_fetch(pair, 0, 0);
        value_sv = av_fetch(pair, 1, 0);
        if (!name_sv || !value_sv || !SvOK(*name_sv) || !SvOK(*value_sv)
            || SvROK(*name_sv) || SvROK(*value_sv)) {
            croak("header %ld name and value must be defined scalars", (long)i);
        }
    }

    nva = (nghttp2_nv *)calloc(count, sizeof(*nva));
    if (!nva) {
        croak("unable to allocate HTTP/2 header block");
    }

    for (i = 0; i <= last; i++) {
        SV **pair_sv = av_fetch(headers, i, 0);
        AV *pair = (AV *)SvRV(*pair_sv);
        SV **name_sv = av_fetch(pair, 0, 0);
        SV **value_sv = av_fetch(pair, 1, 0);
        STRLEN name_len;
        STRLEN value_len;

        nva[i].name = (uint8_t *)SvPVbyte(*name_sv, name_len);
        nva[i].namelen = (size_t)name_len;
        nva[i].value = (uint8_t *)SvPVbyte(*value_sv, value_len);
        nva[i].valuelen = (size_t)value_len;
        nva[i].flags = NGHTTP2_NV_FLAG_NONE;
    }

    return nva;
}

static int
call_scalar_callback(pTHX_ unblock_h2_session *ps, SV *callback, AV *args)
{
    dSP;
    int count;
    int result = 0;
    I32 i;
    I32 len;

    if (!callback || !SvOK(callback)) {
        return 0;
    }

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    len = args ? av_len(args) + 1 : 0;
    for (i = 0; i < len; i++) {
        SV **arg = av_fetch(args, i, 0);
        if (arg) {
            XPUSHs(*arg);
        }
    }

    PUTBACK;
    count = call_sv(callback, G_SCALAR | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        set_callback_error(aTHX_ ps, "HTTP/2 callback failed");
        result = NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    else if (count > 0) {
        SV *return_value = POPs;
        if (SvOK(return_value)) {
            result = (int)SvIV(return_value);
        }
    }

    PUTBACK;
    FREETMPS;
    LEAVE;
    return result;
}

static HV *
frame_to_hv(pTHX_ const nghttp2_frame *frame)
{
    HV *hv = newHV();

    hv_store(hv, "stream_id", 9, newSViv(frame->hd.stream_id), 0);
    hv_store(hv, "type", 4, newSViv(frame->hd.type), 0);
    hv_store(hv, "flags", 5, newSViv(frame->hd.flags), 0);
    hv_store(hv, "length", 6, newSVuv((UV)frame->hd.length), 0);

    if (frame->hd.type == NGHTTP2_HEADERS) {
        hv_store(hv, "headers_category", 16,
            newSViv(frame->headers.cat), 0);
    }
    else if (frame->hd.type == NGHTTP2_GOAWAY) {
        hv_store(hv, "last_stream_id", 14,
            newSViv(frame->goaway.last_stream_id), 0);
        hv_store(hv, "error_code", 10,
            newSVuv((UV)frame->goaway.error_code), 0);
        hv_store(hv, "debug_data", 10,
            newSVpvn(
                frame->goaway.opaque_data
                    ? (const char *)frame->goaway.opaque_data
                    : "",
                frame->goaway.opaque_data_len
            ), 0);
    }

    return hv;
}

static ssize_t
provider_read_callback(
    nghttp2_session *session,
    int32_t stream_id,
    uint8_t *buf,
    size_t length,
    uint32_t *data_flags,
    nghttp2_data_source *source,
    void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    unblock_h2_provider *provider = (unblock_h2_provider *)source->ptr;
    dSP;
    int count;
    ssize_t result = 0;

    if (!provider || provider->released) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        return 0;
    }

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSViv(stream_id)));
    XPUSHs(sv_2mortal(newSVuv((UV)length)));
    PUTBACK;

    count = call_sv(provider->callback, G_ARRAY | G_EVAL);
    SPAGAIN;

    if (provider->released) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        result = 0;
    }
    else if (SvTRUE(ERRSV)) {
        set_callback_error(aTHX_ ps, "HTTP/2 data provider failed");
        result = NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    else if (count == 0) {
        provider->deferred = 1;
        result = NGHTTP2_ERR_DEFERRED;
    }
    else {
        SV **values = SP - count + 1;
        SV *data_sv = values[0];
        SV *eof_sv = count >= 2 ? values[1] : NULL;
        SV *no_end_stream_sv = count >= 3 ? values[2] : NULL;

        if (!SvOK(data_sv)) {
            provider->deferred = 1;
            result = NGHTTP2_ERR_DEFERRED;
        }
        else {
            STRLEN data_len;
            const char *data = SvPVbyte(data_sv, data_len);

            if ((size_t)data_len > length) {
                if (!ps->callback_error) {
                    ps->callback_error = newSVpvf(
                        "HTTP/2 data provider returned %lu bytes with a %lu byte limit",
                        (unsigned long)data_len,
                        (unsigned long)length
                    );
                }
                result = NGHTTP2_ERR_CALLBACK_FAILURE;
            }
            else {
                if (data_len) {
                    memcpy(buf, data, data_len);
                }
                result = (ssize_t)data_len;
                provider->deferred = 0;

                if (eof_sv && SvTRUE(eof_sv)) {
                    *data_flags |= NGHTTP2_DATA_FLAG_EOF;
                    if (no_end_stream_sv && SvTRUE(no_end_stream_sv)) {
                        *data_flags |= NGHTTP2_DATA_FLAG_NO_END_STREAM;
                    }
                }
                else if (data_len == 0) {
                    provider->deferred = 1;
                    result = NGHTTP2_ERR_DEFERRED;
                }
            }
        }
    }

    if (count > 0) {
        SP -= count;
    }
    PUTBACK;
    FREETMPS;
    LEAVE;
    return result;
}

static int
on_begin_headers_callback(nghttp2_session *session,
                          const nghttp2_frame *frame,
                          void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result;

    if (!ps->cb_begin_headers) {
        return 0;
    }

    args = newAV();
    av_push(args, newSViv(frame->hd.stream_id));
    av_push(args, newSViv(frame->hd.type));
    av_push(args, newSViv(frame->hd.flags));
    result = call_scalar_callback(aTHX_ ps, ps->cb_begin_headers, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
on_header_callback(nghttp2_session *session,
                   const nghttp2_frame *frame,
                   const uint8_t *name,
                   size_t namelen,
                   const uint8_t *value,
                   size_t valuelen,
                   uint8_t flags,
                   void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result;

    if (!ps->cb_header) {
        return 0;
    }

    args = newAV();
    av_push(args, newSViv(frame->hd.stream_id));
    av_push(args, newSVpvn((const char *)name, namelen));
    av_push(args, newSVpvn((const char *)value, valuelen));
    av_push(args, newSViv(flags));
    result = call_scalar_callback(aTHX_ ps, ps->cb_header, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
on_frame_recv_callback(nghttp2_session *session,
                       const nghttp2_frame *frame,
                       void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result;

    if (!ps->cb_frame_recv) {
        return 0;
    }

    args = newAV();
    av_push(args, newRV_noinc((SV *)frame_to_hv(aTHX_ frame)));
    result = call_scalar_callback(aTHX_ ps, ps->cb_frame_recv, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
on_data_chunk_recv_callback(nghttp2_session *session,
                            uint8_t flags,
                            int32_t stream_id,
                            const uint8_t *data,
                            size_t len,
                            void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int consume_rv;
    int result;

    consume_rv = nghttp2_session_consume_connection(session, len);
    if (consume_rv != 0) {
        if (!ps->callback_error) {
            ps->callback_error = newSVpvf(
                "nghttp2_session_consume_connection failed (%d): %s",
                consume_rv, nghttp2_strerror(consume_rv)
            );
        }
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    if (!ps->cb_data_chunk_recv) {
        return 0;
    }

    args = newAV();
    av_push(args, newSViv(stream_id));
    av_push(args, newSVpvn((const char *)data, len));
    av_push(args, newSViv(flags));
    result = call_scalar_callback(aTHX_ ps, ps->cb_data_chunk_recv, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
on_stream_close_callback(nghttp2_session *session,
                         int32_t stream_id,
                         uint32_t error_code,
                         void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result = 0;

    remove_provider(aTHX_ ps, stream_id);

    if (!ps->cb_stream_close) {
        return 0;
    }

    args = newAV();
    av_push(args, newSViv(stream_id));
    av_push(args, newSVuv((UV)error_code));
    result = call_scalar_callback(aTHX_ ps, ps->cb_stream_close, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
on_frame_not_send_callback(nghttp2_session *session,
                           const nghttp2_frame *frame,
                           int lib_error_code,
                           void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;

    if (frame->hd.type == NGHTTP2_HEADERS
        && nghttp2_session_get_stream_remote_close(session, frame->hd.stream_id) < 0) {
        remove_provider(aTHX_ ps, frame->hd.stream_id);
    }

    return 0;
}

static int
on_invalid_frame_recv_callback(nghttp2_session *session,
                               const nghttp2_frame *frame,
                               int lib_error_code,
                               void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result;

    if (!ps->cb_invalid_frame) {
        return 0;
    }

    args = newAV();
    av_push(args, newRV_noinc((SV *)frame_to_hv(aTHX_ frame)));
    av_push(args, newSViv(lib_error_code));
    result = call_scalar_callback(aTHX_ ps, ps->cb_invalid_frame, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
error_callback(nghttp2_session *session,
               int lib_error_code,
               const char *msg,
               size_t len,
               void *user_data)
{
    dTHX;
    unblock_h2_session *ps = (unblock_h2_session *)user_data;
    AV *args;
    int result;

    if (!ps->cb_error) {
        return 0;
    }

    args = newAV();
    av_push(args, newSViv(lib_error_code));
    av_push(args, newSVpvn(msg ? msg : "", msg ? len : 0));
    result = call_scalar_callback(aTHX_ ps, ps->cb_error, args);
    SvREFCNT_dec((SV *)args);
    return result;
}

static int
configure_callbacks(pTHX_ nghttp2_session_callbacks **callbacks_out)
{
    nghttp2_session_callbacks *callbacks;
    int rv = nghttp2_session_callbacks_new(&callbacks);

    if (rv != 0) {
        return rv;
    }

    nghttp2_session_callbacks_set_on_begin_headers_callback(
        callbacks, on_begin_headers_callback);
    nghttp2_session_callbacks_set_on_header_callback(
        callbacks, on_header_callback);
    nghttp2_session_callbacks_set_on_frame_recv_callback(
        callbacks, on_frame_recv_callback);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
        callbacks, on_data_chunk_recv_callback);
    nghttp2_session_callbacks_set_on_stream_close_callback(
        callbacks, on_stream_close_callback);
    nghttp2_session_callbacks_set_on_frame_not_send_callback(
        callbacks, on_frame_not_send_callback);
    nghttp2_session_callbacks_set_on_invalid_frame_recv_callback(
        callbacks, on_invalid_frame_recv_callback);
    nghttp2_session_callbacks_set_error_callback2(callbacks, error_callback);

    *callbacks_out = callbacks;
    return 0;
}

static unblock_h2_session *
new_session(pTHX_ HV *callbacks_hv, int server)
{
    unblock_h2_session *ps;
    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_option *option = NULL;
    int rv;

    ps = (unblock_h2_session *)calloc(1, sizeof(*ps));
    if (!ps) {
        croak("unable to allocate HTTP/2 session");
    }

    load_callbacks(aTHX_ ps, callbacks_hv);
    rv = configure_callbacks(aTHX_ &callbacks);
    if (rv != 0) {
        release_callbacks(aTHX_ ps);
        free(ps);
        croak("nghttp2_session_callbacks_new failed (%d): %s",
            rv, nghttp2_strerror(rv));
    }

    rv = nghttp2_option_new(&option);
    if (rv != 0) {
        nghttp2_session_callbacks_del(callbacks);
        release_callbacks(aTHX_ ps);
        free(ps);
        croak("nghttp2_option_new failed (%d): %s",
            rv, nghttp2_strerror(rv));
    }

    nghttp2_option_set_no_auto_window_update(option, 1);

    if (server) {
        rv = nghttp2_session_server_new2(
            &ps->session, callbacks, ps, option);
    }
    else {
        rv = nghttp2_session_client_new2(
            &ps->session, callbacks, ps, option);
    }

    nghttp2_option_del(option);
    nghttp2_session_callbacks_del(callbacks);

    if (rv != 0) {
        release_callbacks(aTHX_ ps);
        free(ps);
        croak("nghttp2 session creation failed (%d): %s",
            rv, nghttp2_strerror(rv));
    }

    return ps;
}

MODULE = Unblock::HTTP2    PACKAGE = Unblock::HTTP2::_nghttp2

PROTOTYPES: DISABLE

int
_available()
    CODE:
        RETVAL = nghttp2_version(0) ? 1 : 0;
    OUTPUT:
        RETVAL

const char *
version_string()
    CODE:
        nghttp2_info *info = nghttp2_version(0);
        RETVAL = info ? info->version_str : "unknown";
    OUTPUT:
        RETVAL

MODULE = Unblock::HTTP2    PACKAGE = Unblock::HTTP2::_nghttp2::Session

SV *
_new_client_xs(class, callbacks_hv)
        char *class
        HV *callbacks_hv
    PREINIT:
        unblock_h2_session *ps;
    CODE:
        ps = new_session(aTHX_ callbacks_hv, 0);
        RETVAL = newSV(0);
        sv_setref_pv(RETVAL, class, (void *)ps);
    OUTPUT:
        RETVAL

SV *
_new_server_xs(class, callbacks_hv)
        char *class
        HV *callbacks_hv
    PREINIT:
        unblock_h2_session *ps;
    CODE:
        ps = new_session(aTHX_ callbacks_hv, 1);
        RETVAL = newSV(0);
        sv_setref_pv(RETVAL, class, (void *)ps);
    OUTPUT:
        RETVAL

void
DESTROY(self)
        SV *self
    PREINIT:
        unblock_h2_session *ps;
        unblock_h2_provider *provider;
    CODE:
        if (!SvROK(self)) {
            XSRETURN_EMPTY;
        }
        ps = INT2PTR(unblock_h2_session *, SvIV(SvRV(self)));
        if (!ps) {
            XSRETURN_EMPTY;
        }

        if (ps->session) {
            nghttp2_session_del(ps->session);
            ps->session = NULL;
        }

        drain_pending_free(aTHX_ ps);
        provider = ps->providers;
        ps->providers = NULL;
        while (provider) {
            unblock_h2_provider *next = provider->next;
            free_provider(aTHX_ provider);
            provider = next;
        }
        release_callbacks(aTHX_ ps);
        free(ps);
        sv_setiv(SvRV(self), 0);

IV
mem_recv(self, data)
        SV *self
        SV *data
    PREINIT:
        unblock_h2_session *ps;
        STRLEN len;
        const char *bytes;
        ssize_t rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        if (ps->in_session_call) {
            croak("mem_recv called from inside an HTTP/2 callback");
        }
        bytes = SvPVbyte(data, len);
        clear_callback_error(aTHX_ ps);

        ENTER;
        SAVEINT(ps->in_session_call);
        ps->in_session_call = 1;
        rv = nghttp2_session_mem_recv(
            ps->session, (const uint8_t *)bytes, (size_t)len);
        LEAVE;
        drain_pending_free(aTHX_ ps);
        croak_callback_error(aTHX_ ps);

        if (rv < 0) {
            croak("nghttp2_session_mem_recv failed (%ld): %s",
                (long)rv, nghttp2_strerror((int)rv));
        }
        RETVAL = (IV)rv;
    OUTPUT:
        RETVAL

SV *
mem_send(self)
        SV *self
    PREINIT:
        unblock_h2_session *ps;
        const uint8_t *data = NULL;
        ssize_t rv = 0;
        SV *output;
    CODE:
        ps = session_from_sv(aTHX_ self);
        if (ps->in_session_call) {
            croak("mem_send called from inside an HTTP/2 callback");
        }
        clear_callback_error(aTHX_ ps);
        output = newSVpvn("", 0);

        ENTER;
        SAVEINT(ps->in_session_call);
        ps->in_session_call = 1;
        for (;;) {
            rv = nghttp2_session_mem_send(ps->session, &data);
            if (rv <= 0) {
                break;
            }
            sv_catpvn(output, (const char *)data, (STRLEN)rv);
        }
        LEAVE;
        drain_pending_free(aTHX_ ps);

        if (ps->callback_error) {
            SvREFCNT_dec(output);
            croak_callback_error(aTHX_ ps);
        }

        if (rv < 0) {
            SvREFCNT_dec(output);
            croak("nghttp2_session_mem_send failed (%ld): %s",
                (long)rv, nghttp2_strerror((int)rv));
        }
        RETVAL = output;
    OUTPUT:
        RETVAL

int
want_read(self)
        SV *self
    PREINIT:
        unblock_h2_session *ps;
    CODE:
        ps = session_from_sv(aTHX_ self);
        RETVAL = nghttp2_session_want_read(ps->session);
    OUTPUT:
        RETVAL

int
want_write(self)
        SV *self
    PREINIT:
        unblock_h2_session *ps;
    CODE:
        ps = session_from_sv(aTHX_ self);
        RETVAL = nghttp2_session_want_write(ps->session);
    OUTPUT:
        RETVAL

int
submit_settings(self, settings_hv)
        SV *self
        HV *settings_hv
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_settings_entry entries[8];
        size_t count = 0;
        SV **value;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);

        if ((value = hv_fetch(settings_hv, "header_table_size", 17, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_HEADER_TABLE_SIZE;
            entries[count++].value = (uint32_t)SvUV(*value);
        }
        if ((value = hv_fetch(settings_hv, "enable_push", 11, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_ENABLE_PUSH;
            entries[count++].value = SvTRUE(*value) ? 1 : 0;
        }
        if ((value = hv_fetch(settings_hv, "max_concurrent_streams", 22, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
            entries[count++].value = (uint32_t)SvUV(*value);
        }
        if ((value = hv_fetch(settings_hv, "initial_window_size", 19, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE;
            entries[count++].value = (uint32_t)SvUV(*value);
        }
        if ((value = hv_fetch(settings_hv, "max_frame_size", 14, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_MAX_FRAME_SIZE;
            entries[count++].value = (uint32_t)SvUV(*value);
        }
        if ((value = hv_fetch(settings_hv, "max_header_list_size", 20, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE;
            entries[count++].value = (uint32_t)SvUV(*value);
        }
        if ((value = hv_fetch(settings_hv, "enable_connect_protocol", 23, 0))) {
            entries[count].settings_id = NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL;
            entries[count++].value = SvTRUE(*value) ? 1 : 0;
        }

        rv = nghttp2_submit_settings(
            ps->session, NGHTTP2_FLAG_NONE, entries, count);
        if (rv != 0) {
            croak("nghttp2_submit_settings failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

UV
remote_setting(self, setting_id)
        SV *self
        int setting_id
    PREINIT:
        unblock_h2_session *ps;
    CODE:
        ps = session_from_sv(aTHX_ self);
        RETVAL = (UV)nghttp2_session_get_remote_settings(
            ps->session, (nghttp2_settings_id)setting_id);
    OUTPUT:
        RETVAL

int
consume_stream(self, stream_id, size)
        SV *self
        int stream_id
        UV size
    PREINIT:
        unblock_h2_session *ps;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        rv = nghttp2_session_consume_stream(
            ps->session, stream_id, (size_t)size);
        if (rv != 0) {
            croak("nghttp2_session_consume_stream failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
get_stream_remote_close(self, stream_id)
        SV *self
        int stream_id
    PREINIT:
        unblock_h2_session *ps;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        rv = nghttp2_session_get_stream_remote_close(ps->session, stream_id);
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
get_stream_local_close(self, stream_id)
        SV *self
        int stream_id
    PREINIT:
        unblock_h2_session *ps;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        rv = nghttp2_session_get_stream_local_close(ps->session, stream_id);
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
_submit_request_native(self, headers_av, provider_sv)
        SV *self
        AV *headers_av
        SV *provider_sv
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        nghttp2_data_provider data_provider;
        nghttp2_data_provider *data_provider_ptr = NULL;
        unblock_h2_provider *provider = NULL;
        int32_t stream_id;
    CODE:
        ps = session_from_sv(aTHX_ self);
        nva = headers_to_nva(aTHX_ headers_av, &nvlen);

        if (SvOK(provider_sv)) {
            if (!SvROK(provider_sv) || SvTYPE(SvRV(provider_sv)) != SVt_PVCV) {
                if (nva) free(nva);
                croak("request data provider must be a coderef");
            }
            provider = (unblock_h2_provider *)calloc(1, sizeof(*provider));
            if (!provider) {
                if (nva) free(nva);
                croak("unable to allocate HTTP/2 data provider");
            }
            provider->callback = newSVsv(provider_sv);
            data_provider.source.ptr = provider;
            data_provider.read_callback = provider_read_callback;
            data_provider_ptr = &data_provider;
        }

        stream_id = nghttp2_submit_request(
            ps->session, NULL, nva, nvlen, data_provider_ptr, NULL);
        if (nva) free(nva);

        if (stream_id < 0) {
            if (provider) free_provider(aTHX_ provider);
            croak("nghttp2_submit_request failed (%d): %s",
                (int)stream_id, nghttp2_strerror((int)stream_id));
        }

        if (provider) {
            provider->stream_id = stream_id;
            add_provider(aTHX_ ps, provider);
        }
        RETVAL = stream_id;
    OUTPUT:
        RETVAL

int
_submit_response_no_body_native(self, stream_id, headers_av)
        SV *self
        int stream_id
        AV *headers_av
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        nva = headers_to_nva(aTHX_ headers_av, &nvlen);
        rv = nghttp2_submit_response(ps->session, stream_id, nva, nvlen, NULL);
        if (nva) free(nva);
        if (rv != 0) {
            croak("nghttp2_submit_response failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
_submit_response_streaming_native(self, stream_id, headers_av, provider_sv)
        SV *self
        int stream_id
        AV *headers_av
        SV *provider_sv
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        nghttp2_data_provider data_provider;
        unblock_h2_provider *provider;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        if (find_provider(ps, stream_id)) {
            croak("stream %d already has a data provider", stream_id);
        }
        if (!SvROK(provider_sv) || SvTYPE(SvRV(provider_sv)) != SVt_PVCV) {
            croak("response data provider must be a coderef");
        }

        nva = headers_to_nva(aTHX_ headers_av, &nvlen);
        provider = (unblock_h2_provider *)calloc(1, sizeof(*provider));
        if (!provider) {
            if (nva) free(nva);
            croak("unable to allocate HTTP/2 data provider");
        }
        provider->stream_id = stream_id;
        provider->callback = newSVsv(provider_sv);
        data_provider.source.ptr = provider;
        data_provider.read_callback = provider_read_callback;

        rv = nghttp2_submit_response(
            ps->session, stream_id, nva, nvlen, &data_provider);
        if (nva) free(nva);
        if (rv != 0) {
            free_provider(aTHX_ provider);
            croak("nghttp2_submit_response failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }

        add_provider(aTHX_ ps, provider);
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
_submit_headers_native(self, stream_id, headers_av, end_stream)
        SV *self
        int stream_id
        AV *headers_av
        int end_stream
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        int32_t rv;
        uint8_t flags;
    CODE:
        ps = session_from_sv(aTHX_ self);
        nva = headers_to_nva(aTHX_ headers_av, &nvlen);
        flags = end_stream ? NGHTTP2_FLAG_END_STREAM : NGHTTP2_FLAG_NONE;
        rv = nghttp2_submit_headers(
            ps->session, flags, stream_id, NULL, nva, nvlen, NULL);
        if (nva) free(nva);
        if (rv < 0) {
            croak("nghttp2_submit_headers failed (%d): %s",
                (int)rv, nghttp2_strerror((int)rv));
        }
        RETVAL = (int)rv;
    OUTPUT:
        RETVAL

int
_submit_trailer_native(self, stream_id, headers_av)
        SV *self
        int stream_id
        AV *headers_av
    PREINIT:
        unblock_h2_session *ps;
        nghttp2_nv *nva;
        size_t nvlen;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        nva = headers_to_nva(aTHX_ headers_av, &nvlen);
        rv = nghttp2_submit_trailer(ps->session, stream_id, nva, nvlen);
        if (nva) free(nva);
        if (rv != 0) {
            croak("nghttp2_submit_trailer failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
submit_rst_stream(self, stream_id, error_code)
        SV *self
        int stream_id
        unsigned int error_code
    PREINIT:
        unblock_h2_session *ps;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        rv = nghttp2_submit_rst_stream(
            ps->session, NGHTTP2_FLAG_NONE, stream_id, error_code);
        if (rv != 0) {
            croak("nghttp2_submit_rst_stream failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
_submit_goaway_native(self, last_stream_id, error_code, debug_data)
        SV *self
        int last_stream_id
        unsigned int error_code
        SV *debug_data
    PREINIT:
        unblock_h2_session *ps;
        STRLEN len = 0;
        const uint8_t *data = NULL;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        if (SvOK(debug_data)) {
            data = (const uint8_t *)SvPVbyte(debug_data, len);
        }
        rv = nghttp2_submit_goaway(
            ps->session, NGHTTP2_FLAG_NONE, last_stream_id,
            error_code, data, (size_t)len);
        if (rv != 0) {
            croak("nghttp2_submit_goaway failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
resume_data(self, stream_id)
        SV *self
        int stream_id
    PREINIT:
        unblock_h2_session *ps;
        int rv;
    CODE:
        ps = session_from_sv(aTHX_ self);
        rv = nghttp2_session_resume_data(ps->session, stream_id);
        if (rv != 0 && rv != NGHTTP2_ERR_INVALID_ARGUMENT) {
            croak("nghttp2_session_resume_data failed (%d): %s",
                rv, nghttp2_strerror(rv));
        }
        RETVAL = rv;
    OUTPUT:
        RETVAL

int
is_stream_deferred(self, stream_id)
        SV *self
        int stream_id
    PREINIT:
        unblock_h2_session *ps;
        unblock_h2_provider *provider;
    CODE:
        ps = session_from_sv(aTHX_ self);
        provider = find_provider(ps, stream_id);
        RETVAL = provider ? provider->deferred : 0;
    OUTPUT:
        RETVAL

void
_clear_deferred(self, stream_id)
        SV *self
        int stream_id
    PREINIT:
        unblock_h2_session *ps;
        unblock_h2_provider *provider;
    CODE:
        ps = session_from_sv(aTHX_ self);
        provider = find_provider(ps, stream_id);
        if (provider) {
            provider->deferred = 0;
        }
