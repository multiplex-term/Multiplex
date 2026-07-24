#ifndef TAILSCALE_H
#define TAILSCALE_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * A Tailscale device, also variously called a "node" or "peer".
 *
 * A device is the unit of identity in a tailnet; it has a tailnet IP and can send and
 * receive IP datagrams to other peers.
 */
typedef struct ts_device ts_device;

/**
 * A Tailscale TCP listener handle.
 */
typedef struct ts_tcp_listener ts_tcp_listener;

/**
 * A Tailscale TCP stream handle.
 */
typedef struct ts_tcp_stream ts_tcp_stream;

/**
 * A Tailscale UDP socket handle.
 */
typedef struct ts_udp_socket ts_udp_socket;

/**
 * A Tailscale cryptographic key.
 */
typedef uint8_t ts_key[32];

/**
 * Tailscale key state for running a device.
 */
typedef struct ts_persisted_key_state {
  /**
   * Private key for the node (device) identity.
   */
  ts_key node_private_key;
  /**
   * Private key for the machine.
   */
  ts_key machine_private_key;
  /**
   * Private key for tailnet lock.
   */
  ts_key network_lock_private_key;
} ts_persisted_key_state;

/**
 * Tailscale configuration.
 *
 * This struct is safe to zero-initialize, in which case default values will be used.
 * You _must_ actually zero-initialize this struct in this case (`struct ts_config config = {0};`);
 * an uninitialized declaration (`struct ts_config config;`) is insufficient and may invoke UB.
 *
 * On the Rust side, the [`Default`] instance for this type is equivalent to a C-side zero-
 * init.
 */
typedef struct ts_config {
  /**
   * The control server URL to use.
   *
   * May be `NULL` to use the default value.
   */
  const char *control_server_url;
  /**
   * The hostname to use. This will be the device's MagicDNS name, if it's available.
   *
   * May be `NULL` to use the default (the OS-reported hostname).
   */
  const char *hostname;
  /**
   * An array of tags to be requested.
   *
   * Use `NULL` as the sentinel for the end of the array.
   *
   * May be `NULL` to indicate that no tags are requested.
   */
  const char *const *tags;
  /**
   * The client name to report to the control server. This is reported as `Hostinfo.App`.
   *
   * May be `NULL` to use the default (`ts_ffi`).
   */
  const char *client_name;
  /**
   * The key state to use.
   *
   * If `NULL`, ephemeral key state is generated.
   */
  struct ts_persisted_key_state *key_state;
} ts_config;

/**
 * IPv4 address.
 */
typedef uint8_t ts_in_addr_t[4];

/**
 * IPv6 address.
 */
typedef uint16_t ts_in6_addr_t[8];

/**
 * Socket address family.
 */
typedef uint16_t ts_sa_family_t;

/**
 * C-compatible IPv4 socket address.
 */
typedef struct ts_sockaddr_in {
  /**
   * Port number.
   */
  uint16_t sin_port;
  /**
   * IPv4 address.
   */
  ts_in_addr_t sin_addr;
} ts_sockaddr_in;

/**
 * C-compatible IPv6 socket address.
 */
typedef struct ts_sockaddr_in6 {
  /**
   * Port number.
   */
  uint16_t sin6_port;
  /**
   * Flow label.
   */
  uint32_t sin6_flowinfo;
  /**
   * IPv6 address.
   */
  ts_in6_addr_t sin6_addr;
  /**
   * Scope id.
   */
  uint32_t sin6_scope_id;
} ts_sockaddr_in6;

/**
 * Address-family-specific payload for a [`sockaddr`].
 *
 * Only `AF_INET` and `AF_INET6` are supported.
 */
typedef union ts_sockaddr_data {
  /**
   * IPv4 sockaddr payload.
   */
  struct ts_sockaddr_in sockaddr_in;
  /**
   * IPv6 sockaddr payload.
   */
  struct ts_sockaddr_in6 sockaddr_in6;
} ts_sockaddr_data;

/**
 * Socket address.
 *
 * Meant for compat between `<sys/socket.h>` `sockaddr`s and tailscale sockets. On most
 * platforms, you should be able to cast directly from the sockaddr types into this struct,
 * though this isn't guaranteed if your libc makes unusual choices.
 */
typedef struct ts_sockaddr {
  /**
   * Address family.
   *
   * Only `AF_INET` and `AF_INET6` are supported.
   */
  ts_sa_family_t sa_family;
  /**
   * The address info payload for this `ts_sockaddr` type.
   */
  union ts_sockaddr_data sa_data;
} ts_sockaddr;

/**
 * IPv4 address family.
 */
#define TS_AF_INET 2

/**
 * IPv6 address family.
 */
#define TS_AF_INET6 23

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Initialize the Rust tailscale tracing subsystem.
 *
 * This is automatically called during `ts_init`, but you may want to call this first to log any
 * errors if initialization needs to be done before `ts_init`.
 */
void ts_init_tracing(void);

/**
 * Initialize a new Tailscale device.
 *
 * `config` is the configuration with which to initialize the device. You may pass `NULL`, and a
 * default ephemeral configuration will be used.
 *
 * `auth_token` is an optional auth token (you may pass `NULL`) that is used to authenticate the
 * device if required. If you pass `NULL`, the credentials in `config_path` must already be
 * authorized to make a successful connection.
 *
 * # Safety
 *
 * `auth_token`  must be able to be read according to [`CStr`] rules, i.e.
 * it must be NUL-terminated and valid for reading up to and including the NUL.
 * The string fields of `config` may be `NULL`, but if they are not, they must
 * obey the same invariants.
 */
struct ts_device *ts_init(const struct ts_config *config, const char *auth_token);

/**
 * Initialize a new Tailscale device with a default configuration using the given key file for the
 * key state. The file is created with new keys if it doesn't exist.
 *
 * `auth_token` is an optional auth token (you may pass `NULL`) that is used to authenticate the
 * device if required. If you pass `NULL`, the credentials in `key_file` must already be
 * authorized to make a successful connection.
 *
 * # Safety
 *
 * `auth_token` and `key_file` must be able to be read according to [`CStr`] rules, i.e.
 * they must be NUL-terminated and valid for reading up to and including the NUL.
 */
struct ts_device *ts_init_from_key_file(const char *key_file, const char *auth_token);

/**
 * Deinitialize and shut down a Tailscale device.
 */
void ts_deinit(struct ts_device *dev);

/**
 * Get the IPv4 address of the Tailscale node, blocking until it's available.
 *
 * Returns a negative number on error.
 */
int ts_ipv4_addr(const struct ts_device *dev, ts_in_addr_t *dst);

/**
 * Get the IPv6 address of the Tailscale node, blocking until it's available.
 *
 * Returns a negative number on error.
 */
int ts_ipv6_addr(const struct ts_device *dev, ts_in6_addr_t *dst);

/**
 * Get the IPv4 address of a specified peer by name.
 *
 * `peer_name` can be a fully-qualified name (`$HOST.tail1234.ts.net`) or an unqualified
 * hostname (`$HOST`). The first match is returned: shared-in nodes may cause ambiguity
 * when unqualified hostnames are used.
 *
 * Returns a negative number if there was an error, zero if no match was found, and a
 * positive number if `addr` has been populated with the address for the requested peer.
 *
 * # Safety
 *
 * `peer_name` must be able to be read according to [`CStr`] rules, i.e.
 * it must be NUL-terminated and valid for reading up to and including the NUL.
 */
int ts_peer_ipv4_addr(const struct ts_device *dev, const char *peer_name, ts_in_addr_t *addr);

/**
 * Get the IPv6 address of a specified peer by name.
 *
 * `peer_name` can be a fully-qualified name (`$HOST.tail1234.ts.net`) or an unqualified
 * hostname (`$HOST`). The first match is returned: shared-in nodes may cause ambiguity
 * when unqualified hostnames are used.
 *
 * Returns a negative number if there was an error, zero if no match was found, and a
 * positive number if `addr` has been populated with the address for the requested peer.
 *
 * # Safety
 *
 * `peer_name` must be able to be read according to [`CStr`] rules, i.e.
 * it must be NUL-terminated and valid for reading up to and including the NUL.
 */
int ts_peer_ipv6_addr(const struct ts_device *dev, const char *peer_name, ts_in6_addr_t *addr);

/**
 * Load the key state from the given file path.
 *
 * The second parameter indicates whether to overwrite the file with a new key state if the
 * contents couldn't be read.
 *
 * Returns a negative number on error.
 *
 * # Safety
 *
 * `path` must be safe to convert to a [`CStr`], i.e. it must be NUL-terminated and valid for read
 * up to the NUL-terminator.
 */
int ts_load_key_file(const char *path,
                     bool overwrite_if_invalid,
                     struct ts_persisted_key_state *key_state);

/**
 * Parse a [`sockaddr`] from a C string.
 *
 * This helper is provided to avoid the need to use `inet_pton`, `getaddrinfo`, and the
 * like if you know you have a string in a conventional `$ADDR:$PORT` shape.
 *
 * # Safety
 *
 * `s` must be able to be read according to [`CStr`] rules, i.e.
 * it must be NUL-terminated and valid for reading up to and including the NUL.
 */
int ts_parse_sockaddr(const char *s, struct ts_sockaddr *addr);

/**
 * Parse an IP address from a string into a [`sockaddr`], setting `sa_family` and the
 * address field. The port is zeroed, and flow info and scope id are left unchanged.
 *
 * This is a convenience to allow easily constructing a `sockaddr` with a string IP,
 * but using a port from a different source.
 *
 * # Safety
 *
 * `s` must be able to be read according to [`CStr`] rules, i.e.
 * it must be NUL-terminated and valid for reading up to and including the NUL.
 */
int ts_parse_ip(const char *s, struct ts_sockaddr *addr);

/**
 * Convenience to set a port on a [`sockaddr`] regardless of its `sa_family`.
 *
 * Returns a negative number if `sa_family` is invalid.
 */
int ts_sockaddr_set_port(struct ts_sockaddr *addr, uint16_t port);

/**
 * Start a TCP listener on the given `addr`.
 *
 * Returns null if the listener couldn't be created.
 */
struct ts_tcp_listener *ts_tcp_listen(const struct ts_device *dev, const struct ts_sockaddr *addr);

/**
 * Accept an incoming connection on the given listener.
 *
 * Returns null if there was an error.
 */
struct ts_tcp_stream *ts_tcp_accept(const struct ts_tcp_listener *listener);

/**
 * Get the local endpoint `listener` is listening on.
 */
struct ts_sockaddr ts_tcp_listener_local_addr(const struct ts_tcp_listener *listener);

/**
 * Close the specified socket.
 */
void ts_tcp_close_listener(struct ts_tcp_listener *sock);

/**
 * Open a TCP connection to the specified `remote`.
 */
struct ts_tcp_stream *ts_tcp_connect(const struct ts_device *dev, const struct ts_sockaddr *remote);

/**
 * Send bytes to the specified socket, blocking until at least one byte is sent.
 *
 * Returns the number of bytes written, or a negative number if an error occurred. This is
 * guaranteed to be less than or equal to `len`.
 *
 * # Safety
 *
 * `buf` must be safe to convert into a Rust slice of length `len` (see
 * [`core::slice::from_raw_parts`]).
 */
int ts_tcp_send(const struct ts_tcp_stream *stream, const uint8_t *buf, uintptr_t len);

/**
 * Receive bytes from the specified socket, blocking until at least one byte is received.
 *
 * Returns the number of bytes read, or a negative number if an error occurred. This is
 * guaranteed to be less than or equal to `len`.
 *
 * # Safety
 *
 * `buf` must be safe to convert into a mutable Rust slice of length `len` (see
 * [`core::slice::from_raw_parts_mut`]).
 */
int ts_tcp_recv(const struct ts_tcp_stream *stream, uint8_t *buf, uintptr_t len);

/**
 * Get the local endpoint for this TCP stream.
 */
struct ts_sockaddr ts_tcp_local_addr(const struct ts_tcp_stream *stream);

/**
 * Get the remote endpoint this TCP stream is connected to.
 */
struct ts_sockaddr ts_tcp_remote_addr(const struct ts_tcp_stream *stream);

/**
 * Close the specified socket.
 */
void ts_tcp_close(struct ts_tcp_stream *sock);

/**
 * Bind a UDP socket on `addr`.
 *
 * Returns null if an error occurred.
 */
struct ts_udp_socket *ts_udp_bind(const struct ts_device *dev, const struct ts_sockaddr *addr);

/**
 * Close the specified UDP socket.
 */
void ts_udp_close(struct ts_udp_socket *sock);

/**
 * Send data over the specified socket to the given `addr`.
 *
 * Returns a negative number if an error occurred.
 *
 * # Safety
 *
 * `buf` must be safe to convert into a Rust slice of length `len` (see
 * [`core::slice::from_raw_parts`]).
 */
int ts_udp_sendto(const struct ts_udp_socket *sock,
                  const struct ts_sockaddr *addr,
                  const uint8_t *msg,
                  uintptr_t len);

/**
 * Receive a packet from the socket.
 *
 * `addr` may be `None` (null) if the sender's address isn't needed.
 *
 * Returns the length of the packet, or a negative number on error. This is guaranteed to
 * be less than or equal to `len`.
 *
 * # Safety
 *
 * `buf` must be safe to convert into a mutable Rust slice of length `len` (see
 * [`core::slice::from_raw_parts_mut`]).
 */
int ts_udp_recvfrom(const struct ts_udp_socket *sock,
                    struct ts_sockaddr *addr,
                    uint8_t *buf,
                    uintptr_t len);

/**
 * Get the local endpoint to which the socket is bound.
 */
struct ts_sockaddr ts_udp_local_addr(const struct ts_udp_socket *sock);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* TAILSCALE_H */
