// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
/*
 * Default-deny network guard for one unprivileged lab UID in the test VM.
 * The allowlist is exactly one IPv4 TCP registry endpoint.
 */
#include "vmlinux.h"
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#ifndef LAB_UID
#error "Set LAB_UID to the dedicated unprivileged workload UID"
#endif
#ifndef LAB_IPV4
#error "Set LAB_IPV4 to the registry IPv4 address in host byte order"
#endif
#ifndef LAB_PORT
#error "Set LAB_PORT to the registry TCP port"
#endif

#define AF_UNIX 1
#define AF_INET 2
#define EACCES 13
#define SOCK_STREAM 1
#define SOCK_TYPE_MASK 0xf
#define TCP_PROTOCOL 6

char _license[] SEC("license") = "Dual BSD/GPL";

static __always_inline int scoped(void)
{
	return (__u32)bpf_get_current_uid_gid() == LAB_UID;
}

static __always_inline int allowed_peer(__be32 address, __be16 port)
{
	return address == bpf_htonl(LAB_IPV4) && port == bpf_htons(LAB_PORT)
		? 0 : -EACCES;
}

static __always_inline int check_peer(const struct sockaddr *address, int len)
{
	struct sockaddr_in peer;

	if (!address || len < (int)sizeof(peer) ||
	    bpf_probe_read_kernel(&peer, sizeof(peer), address))
		return -EACCES;
	if (peer.sin_family != AF_INET)
		return -EACCES;
	return allowed_peer(peer.sin_addr.s_addr, peer.sin_port);
}

SEC("lsm/socket_create")
int BPF_PROG(lab_socket_create, int family, int type, int protocol,
	     int kern, int ret)
{
	if (ret || kern || !scoped())
		return ret;
	/* Allow local socketpairs. Connect and addressed sends are checked. */
	if (family == AF_UNIX)
		return 0;
	if (family == AF_INET && (type & SOCK_TYPE_MASK) == SOCK_STREAM &&
	    (!protocol || protocol == TCP_PROTOCOL))
		return 0;
	return -EACCES;
}

SEC("lsm/socket_connect")
int BPF_PROG(lab_socket_connect, struct socket *sock, struct sockaddr *address,
	     int addrlen, int ret)
{
	if (ret || !scoped())
		return ret;
	return check_peer(address, addrlen);
}

SEC("lsm/socket_sendmsg")
int BPF_PROG(lab_socket_sendmsg, struct socket *sock, struct msghdr *msg,
	     int size, int ret)
{
	struct sockaddr *address;
	struct sock *sk;

	if (ret || !scoped())
		return ret;
	address = msg->msg_name;
	if (address)
		return check_peer(address, msg->msg_namelen);
	sk = sock->sk;
	if (!sk)
		return -EACCES;
	if (sk->__sk_common.skc_family == AF_UNIX)
		return 0;
	if (sk->__sk_common.skc_family != AF_INET)
		return -EACCES;
	return allowed_peer(sk->__sk_common.skc_daddr,
			    sk->__sk_common.skc_dport);
}
