//! Verification for the "My VPN" privacy mode.
//!
//! The app cannot ask a third-party VPN client whether it is connected, and
//! it cannot see inside the tunnel. What it can see, locally and without
//! sending anything, is where the system would route a packet to the
//! internet right now: the default route's interface, that interface's
//! addresses, and the resolvers in effect. A fingerprint captured while the
//! user's VPN is up records those facts; verification re-reads them and
//! compares. Interface names are never identity (utun numbering is
//! dynamic); the match is on the resolver set or the tunnel's subnet.
//!
//! Everything that touches the system goes through `observe()`. The match
//! logic takes a `NetworkFacts` value so tests use synthetic facts.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use serde::{Deserialize, Serialize};

use crate::error::AppError;

/// What was true of the network while the user's VPN was up, as captured
/// by "Register this VPN". Device-local: the app persists it outside the
/// synced library and pushes it into the core at launch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct VpnFingerprint {
    /// The user's name for it ("NordVPN").
    pub label: String,
    /// Interface family carrying the default route at capture ("utun",
    /// "ipsec", "ppp"). Shown to the user; never used for matching.
    pub tunnel_kind: String,
    /// The tunnel's address and prefix at capture, e.g. "10.5.0.2/16".
    /// Matches when the current tunnel address is inside it.
    pub subnet: String,
    /// Resolvers in effect at capture. Matches when the current set is the
    /// same; the primary match, since providers keep their resolvers.
    pub dns: Vec<String>,
    pub captured_at_ms: u64,
}

/// The result of comparing the network now with the registered fingerprint.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum VpnStatus {
    /// The default route is a tunnel and it matches the fingerprint.
    Matched,
    /// The default route is a tunnel but not the registered one. `seen` is
    /// a one-line description for the status UI ("utun5 10.8.0.3/24, DNS
    /// 1.1.1.1"), or what bypasses it when IPv6 would leave the tunnel.
    DifferentTunnel { seen: String },
    /// The default route is a plain interface: no VPN is carrying traffic.
    NoTunnel,
    /// Mode is VPN but nothing has been registered yet.
    NotRegistered,
    /// The system could not be inspected; the message says why.
    Unknown { message: String },
}

/// One address on one interface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IfaceAddr {
    pub iface: String,
    pub addr: IpAddr,
    pub prefix: u8,
}

/// A snapshot of what verification looks at.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct NetworkFacts {
    /// Interface the IPv4 default path uses, if any route would carry a
    /// packet to a public IPv4 address.
    pub default_iface_v4: Option<String>,
    /// Same for IPv6. A VPN that tunnels only IPv4 while the system has a
    /// native IPv6 path would leak; verification treats that as a mismatch.
    pub default_iface_v6: Option<String>,
    pub addrs: Vec<IfaceAddr>,
    pub dns: Vec<IpAddr>,
}

/// Interface families that are tunnels, by name prefix.
const TUNNEL_KINDS: [&str; 5] = ["utun", "ipsec", "ppp", "tun", "tap"];

/// The tunnel family of an interface name, or None for a plain interface.
pub(crate) fn tunnel_kind(iface: &str) -> Option<&'static str> {
    TUNNEL_KINDS.iter().copied().find(|k| {
        iface.starts_with(k) && iface[k.len()..].chars().all(|c| c.is_ascii_digit())
    })
}

/// The address verification compares against the subnet: the tunnel's
/// first global address, IPv4 preferred.
fn tunnel_addr<'a>(facts: &'a NetworkFacts, iface: &str) -> Option<&'a IfaceAddr> {
    let on_iface = || facts.addrs.iter().filter(|a| a.iface == iface && is_global(a.addr));
    on_iface().find(|a| a.addr.is_ipv4()).or_else(|| on_iface().next())
}

fn is_global(addr: IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => !v4.is_loopback() && !v4.is_link_local() && !v4.is_unspecified(),
        IpAddr::V6(v6) => {
            !v6.is_loopback() && !v6.is_unspecified() && (v6.segments()[0] & 0xffc0) != 0xfe80
        }
    }
}

fn in_subnet(addr: IpAddr, subnet: &str) -> bool {
    let Some((base, prefix)) = subnet.split_once('/') else { return false };
    let Ok(prefix) = prefix.parse::<u32>() else { return false };
    match (addr, base.parse::<IpAddr>()) {
        (IpAddr::V4(a), Ok(IpAddr::V4(b))) if prefix <= 32 => {
            let mask = if prefix == 0 { 0 } else { u32::MAX << (32 - prefix) };
            u32::from(a) & mask == u32::from(b) & mask
        }
        (IpAddr::V6(a), Ok(IpAddr::V6(b))) if prefix <= 128 => {
            let mask = if prefix == 0 { 0 } else { u128::MAX << (128 - prefix) };
            u128::from(a) & mask == u128::from(b) & mask
        }
        _ => false,
    }
}

fn same_dns(saved: &[String], now: &[IpAddr]) -> bool {
    if saved.is_empty() || now.is_empty() { return false }
    let mut a: Vec<String> = saved.to_vec();
    let mut b: Vec<String> = now.iter().map(ToString::to_string).collect();
    a.sort();
    a.dedup();
    b.sort();
    b.dedup();
    a == b
}

fn describe(facts: &NetworkFacts, iface: &str) -> String {
    let addr = tunnel_addr(facts, iface)
        .map(|a| format!(" {}/{}", a.addr, a.prefix))
        .unwrap_or_default();
    let dns = if facts.dns.is_empty() {
        String::new()
    } else {
        format!(", DNS {}", facts.dns.iter().map(ToString::to_string).collect::<Vec<_>>().join(" "))
    };
    format!("{iface}{addr}{dns}")
}

/// Build a fingerprint from the network as it is now. Fails when no tunnel
/// is carrying the default route, so a fingerprint is never captured from
/// an unprotected connection.
pub(crate) fn capture(label: &str, facts: &NetworkFacts, now_ms: u64) -> Result<VpnFingerprint, AppError> {
    let label = label.trim();
    if label.is_empty() {
        return Err(AppError::NetworkError("Give the VPN a name first.".into()));
    }
    let Some(iface) = facts.default_iface_v4.as_deref() else {
        return Err(AppError::NetworkError("No network route is active right now.".into()));
    };
    let Some(kind) = tunnel_kind(iface) else {
        return Err(AppError::NetworkError(format!(
            "Your traffic is going out through {iface}, not a VPN tunnel. Connect the VPN first."
        )));
    };
    let subnet = tunnel_addr(facts, iface)
        .map(|a| format!("{}/{}", a.addr, a.prefix))
        .unwrap_or_default();
    let dns: Vec<String> = facts.dns.iter().map(ToString::to_string).collect();
    if subnet.is_empty() && dns.is_empty() {
        return Err(AppError::NetworkError(
            "The tunnel has no address or resolvers to recognise it by.".into(),
        ));
    }
    Ok(VpnFingerprint {
        label: label.to_string(),
        tunnel_kind: kind.to_string(),
        subnet,
        dns,
        captured_at_ms: now_ms,
    })
}

/// Compare the network now with a fingerprint.
pub(crate) fn verify(fp: &VpnFingerprint, facts: &NetworkFacts) -> VpnStatus {
    let Some(iface) = facts.default_iface_v4.as_deref() else { return VpnStatus::NoTunnel };
    if tunnel_kind(iface).is_none() {
        return VpnStatus::NoTunnel;
    }
    if let Some(v6) = facts.default_iface_v6.as_deref() {
        if tunnel_kind(v6).is_none() {
            return VpnStatus::DifferentTunnel { seen: format!("IPv6 traffic would bypass the tunnel through {v6}") };
        }
    }
    let dns_ok = same_dns(&fp.dns, &facts.dns);
    let subnet_ok = tunnel_addr(facts, iface).is_some_and(|a| in_subnet(a.addr, &fp.subnet));
    if dns_ok || subnet_ok {
        VpnStatus::Matched
    } else {
        VpnStatus::DifferentTunnel { seen: describe(facts, iface) }
    }
}

/// Read the facts from the system. Local inspection only: nothing is sent.
pub(crate) fn observe() -> Result<NetworkFacts, AppError> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        sys::observe()
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        Err(AppError::NetworkError("VPN verification is not available on this platform.".into()))
    }
}

/// Darwin: routing table via `sysctl`, addresses via `getifaddrs`,
/// resolvers via libresolv. All unprivileged and sandbox-safe on both
/// platforms.
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod sys {
    use super::*;
    use std::ffi::CStr;
    use std::mem::size_of;

    /// Probe destinations for "where would a packet to the internet go":
    /// documentation ranges that no local route ever covers, so the answer
    /// is always the most general matching route.
    const PROBE_V4: Ipv4Addr = Ipv4Addr::new(203, 0, 113, 1);
    const PROBE_V6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);

    pub(super) fn observe() -> Result<NetworkFacts, AppError> {
        let routes = route_dump()?;
        Ok(NetworkFacts {
            default_iface_v4: best_route(&routes, IpAddr::V4(PROBE_V4)),
            default_iface_v6: best_route(&routes, IpAddr::V6(PROBE_V6)),
            addrs: interface_addrs()?,
            dns: resolvers(),
        })
    }

    struct Route {
        dst: IpAddr,
        prefix: u8,
        iface: String,
    }

    const RTM_VERSION: u8 = 5;
    const RTF_HOST: libc::c_int = 0x4;
    const RTF_LLINFO: libc::c_int = 0x400;
    const RTAX_DST: usize = 0;
    const RTAX_NETMASK: usize = 2;
    const RTAX_MAX: usize = 8;

    /// Round a sockaddr length up to the next 4-byte boundary, as the
    /// kernel lays them out after `rt_msghdr`.
    fn roundup(len: usize) -> usize {
        if len == 0 { 4 } else { (len + 3) & !3 }
    }

    fn route_dump() -> Result<Vec<Route>, AppError> {
        let mut mib = [libc::CTL_NET, libc::PF_ROUTE, 0, 0, libc::NET_RT_DUMP, 0];
        let mut len: libc::size_t = 0;
        // SAFETY: a size query; no buffer is written.
        if unsafe { libc::sysctl(mib.as_mut_ptr(), 6, std::ptr::null_mut(), &mut len, std::ptr::null_mut(), 0) } < 0 {
            return Err(AppError::NetworkError(format!("routing table size: {}", std::io::Error::last_os_error())));
        }
        let mut buf = vec![0u8; len];
        // SAFETY: the buffer is at least `len` bytes; the kernel updates `len`
        // to what it wrote.
        if unsafe { libc::sysctl(mib.as_mut_ptr(), 6, buf.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) } < 0 {
            return Err(AppError::NetworkError(format!("routing table: {}", std::io::Error::last_os_error())));
        }
        buf.truncate(len);
        Ok(parse_routes(&buf))
    }

    fn parse_routes(buf: &[u8]) -> Vec<Route> {
        let mut routes = Vec::new();
        let mut off = 0;
        while off + size_of::<libc::rt_msghdr>() <= buf.len() {
            // SAFETY: bounds checked above; read_unaligned copes with the
            // kernel's packing.
            let hdr: libc::rt_msghdr = unsafe { std::ptr::read_unaligned(buf.as_ptr().add(off).cast()) };
            let msglen = hdr.rtm_msglen as usize;
            if msglen < size_of::<libc::rt_msghdr>() || off + msglen > buf.len() { break }
            let msg = &buf[off..off + msglen];
            off += msglen;
            if hdr.rtm_version != RTM_VERSION { continue }
            let flags = hdr.rtm_flags;
            if flags & libc::RTF_UP == 0 || flags & libc::RTF_IFSCOPE != 0 || flags & RTF_LLINFO != 0 {
                continue;
            }
            if hdr.rtm_addrs & libc::RTA_DST == 0 { continue }
            let mut sa_off = size_of::<libc::rt_msghdr>();
            let mut dst = None;
            let mut mask: Option<Option<IpAddr>> = None;
            for i in 0..RTAX_MAX {
                if hdr.rtm_addrs & (1 << i) == 0 { continue }
                if sa_off >= msg.len() { break }
                let sa = &msg[sa_off..];
                let sa_len = sa[0] as usize;
                match i {
                    RTAX_DST => dst = sockaddr_ip(sa),
                    RTAX_NETMASK => mask = Some(sockaddr_ip(sa)),
                    _ => {}
                }
                sa_off += roundup(sa_len);
            }
            let Some(dst) = dst else { continue };
            let prefix = if flags & RTF_HOST != 0 {
                if dst.is_ipv4() { 32 } else { 128 }
            } else {
                match mask {
                    Some(Some(m)) => mask_prefix(m),
                    // A netmask slot of zero length is the all-zero mask.
                    Some(None) => 0,
                    None => if dst.is_ipv4() { 32 } else { 128 },
                }
            };
            let mut name = [0 as libc::c_char; libc::IF_NAMESIZE];
            // SAFETY: the buffer is IF_NAMESIZE; the call writes a NUL-terminated name or returns null.
            let p = unsafe { libc::if_indextoname(hdr.rtm_index as libc::c_uint, name.as_mut_ptr()) };
            if p.is_null() { continue }
            // SAFETY: non-null means a NUL-terminated string within the buffer.
            let iface = unsafe { CStr::from_ptr(name.as_ptr()) }.to_string_lossy().into_owned();
            routes.push(Route { dst, prefix, iface });
        }
        routes
    }

    /// The IP in a sockaddr blob, tolerating the truncated forms the kernel
    /// uses for netmasks (missing trailing bytes are zero).
    fn sockaddr_ip(sa: &[u8]) -> Option<IpAddr> {
        let sa_len = sa[0] as usize;
        if sa_len == 0 { return None }
        let family = sa[1] as libc::c_int;
        let avail = sa_len.min(sa.len());
        match family {
            libc::AF_INET => {
                let mut b = [0u8; 4];
                for (i, slot) in b.iter_mut().enumerate() {
                    if 4 + i < avail { *slot = sa[4 + i] }
                }
                Some(IpAddr::V4(Ipv4Addr::from(b)))
            }
            libc::AF_INET6 => {
                let mut b = [0u8; 16];
                for (i, slot) in b.iter_mut().enumerate() {
                    if 8 + i < avail { *slot = sa[8 + i] }
                }
                Some(IpAddr::V6(Ipv6Addr::from(b)))
            }
            _ => None,
        }
    }

    fn mask_prefix(mask: IpAddr) -> u8 {
        match mask {
            IpAddr::V4(m) => u32::from(m).count_ones() as u8,
            IpAddr::V6(m) => u128::from(m).count_ones() as u8,
        }
    }

    /// Longest-prefix match for `probe` over the dump: the interface a
    /// packet to it would leave through. Handles a replaced default route
    /// and the 0/1 + 128/1 pair VPN clients use to override one.
    fn best_route(routes: &[Route], probe: IpAddr) -> Option<String> {
        routes
            .iter()
            .filter(|r| r.dst.is_ipv4() == probe.is_ipv4() && in_subnet(probe, &format!("{}/{}", r.dst, r.prefix)))
            .max_by_key(|r| r.prefix)
            .map(|r| r.iface.clone())
    }

    fn interface_addrs() -> Result<Vec<IfaceAddr>, AppError> {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        // SAFETY: getifaddrs allocates the list; freed below.
        if unsafe { libc::getifaddrs(&mut list) } != 0 {
            return Err(AppError::NetworkError(format!("interfaces: {}", std::io::Error::last_os_error())));
        }
        let mut out = Vec::new();
        let mut cur = list;
        while !cur.is_null() {
            // SAFETY: a node of the list getifaddrs returned.
            let ifa = unsafe { &*cur };
            cur = ifa.ifa_next;
            if ifa.ifa_addr.is_null() || (ifa.ifa_flags as libc::c_int) & libc::IFF_UP == 0 { continue }
            // SAFETY: ifa_addr is a sockaddr with a valid sa_len.
            let sa_len = unsafe { (*ifa.ifa_addr).sa_len } as usize;
            // SAFETY: sa_len bytes are readable from ifa_addr.
            let sa = unsafe { std::slice::from_raw_parts(ifa.ifa_addr.cast::<u8>(), sa_len.max(2)) };
            let Some(addr) = sockaddr_ip(sa) else { continue };
            if !is_global(addr) { continue }
            let prefix = if ifa.ifa_netmask.is_null() {
                if addr.is_ipv4() { 32 } else { 128 }
            } else {
                // SAFETY: as for ifa_addr.
                let m_len = unsafe { (*ifa.ifa_netmask).sa_len } as usize;
                // SAFETY: m_len bytes are readable from ifa_netmask.
                let m = unsafe { std::slice::from_raw_parts(ifa.ifa_netmask.cast::<u8>(), m_len.max(2)) };
                sockaddr_ip(m).map(mask_prefix).unwrap_or(0)
            };
            // SAFETY: ifa_name is a NUL-terminated string owned by the list.
            let iface = unsafe { CStr::from_ptr(ifa.ifa_name) }.to_string_lossy().into_owned();
            out.push(IfaceAddr { iface, addr, prefix });
        }
        // SAFETY: the list came from getifaddrs and is not used after this.
        unsafe { libc::freeifaddrs(list) };
        Ok(out)
    }

    /// `union res_sockaddr_union` is 128 bytes on Darwin.
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct ResSockaddr([u8; 128]);

    #[link(name = "resolv")]
    extern "C" {
        fn res_9_ninit(statp: *mut libc::c_void) -> libc::c_int;
        fn res_9_getservers(statp: *mut libc::c_void, set: *mut ResSockaddr, cnt: libc::c_int) -> libc::c_int;
        fn res_9_ndestroy(statp: *mut libc::c_void);
    }

    /// The resolvers in effect. `struct __res_state` is 552 bytes on both
    /// platforms' current SDKs; the buffer is well past that so a larger
    /// SDK layout cannot overrun it.
    fn resolvers() -> Vec<IpAddr> {
        const MAXNS: usize = 3;
        let mut state = vec![0u64; 512];
        let statp = state.as_mut_ptr().cast::<libc::c_void>();
        // SAFETY: statp points at 4 KiB of writable, 8-byte-aligned memory,
        // far larger than the resolver state it initialises.
        if unsafe { res_9_ninit(statp) } != 0 { return Vec::new() }
        let mut servers = [ResSockaddr([0; 128]); MAXNS];
        // SAFETY: `servers` holds MAXNS entries of the union's size.
        let n = unsafe { res_9_getservers(statp, servers.as_mut_ptr(), MAXNS as libc::c_int) };
        // SAFETY: the state was initialised by res_9_ninit above.
        unsafe { res_9_ndestroy(statp) };
        servers
            .iter()
            .take(n.max(0) as usize)
            .filter_map(|s| sockaddr_ip(&s.0))
            .filter(|a| !a.is_unspecified())
            .collect()
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn observe_reads_the_live_system() {
            // The machine running tests has some route; the call must not
            // error, and the parsers must cope with whatever is there.
            let facts = observe().unwrap();
            assert!(!facts.addrs.is_empty() || facts.default_iface_v4.is_none());
        }

        /// Diagnostic: `./scripts/test-rust.sh print_live_network_facts -- --ignored --nocapture`
        /// prints what verification sees on this machine right now.
        #[test]
        #[ignore]
        fn print_live_network_facts() {
            let facts = observe().unwrap();
            println!("default v4: {:?}", facts.default_iface_v4);
            println!("default v6: {:?}", facts.default_iface_v6);
            for a in &facts.addrs {
                println!("  {} {}/{}", a.iface, a.addr, a.prefix);
            }
            println!("dns: {:?}", facts.dns);
        }

        #[test]
        fn netmask_sockaddr_may_be_truncated() {
            // AF_INET netmask 255.255.0.0 as the kernel emits it: 6 bytes.
            let sa = [6u8, libc::AF_INET as u8, 0, 0, 255, 255];
            assert_eq!(sockaddr_ip(&sa), Some(IpAddr::V4(Ipv4Addr::new(255, 255, 0, 0))));
            assert_eq!(sockaddr_ip(&[0u8, 0]), None);
        }

        #[test]
        fn best_route_prefers_the_longest_prefix() {
            let routes = vec![
                Route { dst: "0.0.0.0".parse().unwrap(), prefix: 0, iface: "en0".into() },
                Route { dst: "0.0.0.0".parse().unwrap(), prefix: 1, iface: "utun4".into() },
                Route { dst: "128.0.0.0".parse().unwrap(), prefix: 1, iface: "utun4".into() },
                Route { dst: "192.168.1.0".parse().unwrap(), prefix: 24, iface: "en0".into() },
            ];
            assert_eq!(best_route(&routes, IpAddr::V4(PROBE_V4)).as_deref(), Some("utun4"));
            assert_eq!(best_route(&routes, IpAddr::V6(PROBE_V6)), None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(v4: &str, addr: &str, prefix: u8, dns: &[&str]) -> NetworkFacts {
        NetworkFacts {
            default_iface_v4: Some(v4.to_string()),
            default_iface_v6: None,
            addrs: vec![IfaceAddr { iface: v4.to_string(), addr: addr.parse().unwrap(), prefix }],
            dns: dns.iter().map(|d| d.parse().unwrap()).collect(),
        }
    }

    fn nord() -> VpnFingerprint {
        capture("NordVPN", &facts("utun4", "10.5.0.2", 16, &["103.86.96.100", "103.86.99.100"]), 1).unwrap()
    }

    #[test]
    fn tunnel_kinds_by_name() {
        assert_eq!(tunnel_kind("utun4"), Some("utun"));
        assert_eq!(tunnel_kind("ipsec0"), Some("ipsec"));
        assert_eq!(tunnel_kind("ppp0"), Some("ppp"));
        assert_eq!(tunnel_kind("en0"), None);
        assert_eq!(tunnel_kind("utunnel"), None);
    }

    #[test]
    fn capture_records_subnet_and_dns() {
        let fp = nord();
        assert_eq!(fp.label, "NordVPN");
        assert_eq!(fp.tunnel_kind, "utun");
        assert_eq!(fp.subnet, "10.5.0.2/16");
        assert_eq!(fp.dns, vec!["103.86.96.100", "103.86.99.100"]);
    }

    #[test]
    fn capture_refuses_a_plain_interface_or_no_route() {
        let err = capture("NordVPN", &facts("en0", "192.168.1.5", 24, &["192.168.1.1"]), 1).unwrap_err();
        assert!(err.to_string().contains("en0"), "{err}");
        let none = NetworkFacts::default();
        assert!(capture("NordVPN", &none, 1).is_err());
        assert!(capture("  ", &facts("utun4", "10.5.0.2", 16, &[]), 1).is_err());
    }

    #[test]
    fn verify_matches_on_dns_or_subnet() {
        let fp = nord();
        // Same resolvers, different server subnet: a server switch.
        let moved = facts("utun7", "10.6.0.9", 16, &["103.86.99.100", "103.86.96.100"]);
        assert_eq!(verify(&fp, &moved), VpnStatus::Matched);
        // Same subnet, resolvers unavailable.
        let no_dns = facts("utun2", "10.5.3.4", 16, &[]);
        assert_eq!(verify(&fp, &no_dns), VpnStatus::Matched);
    }

    #[test]
    fn verify_reports_other_tunnels_and_none() {
        let fp = nord();
        let other = facts("utun5", "10.8.0.3", 24, &["1.1.1.1"]);
        assert_eq!(verify(&fp, &other), VpnStatus::DifferentTunnel { seen: "utun5 10.8.0.3/24, DNS 1.1.1.1".into() });
        let plain = facts("en0", "192.168.1.5", 24, &["192.168.1.1"]);
        assert_eq!(verify(&fp, &plain), VpnStatus::NoTunnel);
        assert_eq!(verify(&fp, &NetworkFacts::default()), VpnStatus::NoTunnel);
    }

    #[test]
    fn verify_flags_an_ipv6_path_outside_the_tunnel() {
        let fp = nord();
        let mut leaky = facts("utun4", "10.5.0.2", 16, &["103.86.96.100", "103.86.99.100"]);
        leaky.default_iface_v6 = Some("en0".into());
        assert!(matches!(verify(&fp, &leaky), VpnStatus::DifferentTunnel { ref seen } if seen.contains("en0")));
        leaky.default_iface_v6 = Some("utun4".into());
        assert_eq!(verify(&fp, &leaky), VpnStatus::Matched);
    }

    #[test]
    fn fingerprint_round_trips_through_json() {
        let fp = nord();
        let json = serde_json::to_string(&fp).unwrap();
        assert_eq!(serde_json::from_str::<VpnFingerprint>(&json).unwrap(), fp);
    }
}
