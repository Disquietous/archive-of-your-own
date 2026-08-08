use std::sync::Arc;

// ---------------------------------------------------------------------------
// Embedded SOCKS5 proxy (Tor transport)
// ---------------------------------------------------------------------------

/// Run a minimal SOCKS5 proxy that bridges local TCP connections through the
/// Tor network. Only SOCKS5 CONNECT (command 0x01) with domain-name addresses
/// (address type 0x03), IPv4 (0x01), and IPv6 (0x04) is supported — this is
/// exactly what `reqwest` sends when configured with `socks5h://`.
#[cfg(feature = "tor")]
pub(super) async fn run_socks_proxy(
    listener: tokio::net::TcpListener,
    tor: Arc<arti_client::TorClient<tor_rtcompat::PreferredRuntime>>,
) {
    loop {
        let (stream, _addr) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => continue,
        };
        let tor = Arc::clone(&tor);
        tokio::spawn(async move {
            if let Err(_e) = handle_socks_connection(stream, &tor).await {
                // Connection-level errors are silently dropped; the caller
                // (reqwest) will surface a network error.
            }
        });
    }
}

/// Handle one inbound SOCKS5 connection.
///
/// Protocol reference: RFC 1928
#[cfg(feature = "tor")]
async fn handle_socks_connection(
    mut stream: tokio::net::TcpStream,
    tor: &arti_client::TorClient<tor_rtcompat::PreferredRuntime>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use arti_client::IntoTorAddr;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    stream.set_nodelay(true)?;

    // --- Greeting -----------------------------------------------------------
    // Client sends: VER | NMETHODS | METHODS...
    let mut buf = [0u8; 2];
    stream.read_exact(&mut buf).await?;
    let ver = buf[0];
    let nmethods = buf[1] as usize;
    if ver != 0x05 {
        return Err("unsupported SOCKS version".into());
    }
    let mut methods = vec![0u8; nmethods];
    stream.read_exact(&mut methods).await?;

    // We only support "no authentication" (0x00).
    stream.write_all(&[0x05, 0x00]).await?;

    // --- Request ------------------------------------------------------------
    // Client sends: VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).await?;
    let cmd = header[1];
    let atyp = header[3];

    if cmd != 0x01 {
        // Only CONNECT is supported.
        let reply = [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
        stream.write_all(&reply).await?;
        return Err("unsupported SOCKS command".into());
    }

    let (host, port) = match atyp {
        // IPv4
        0x01 => {
            let mut addr = [0u8; 4];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let ip = std::net::Ipv4Addr::from(addr);
            (ip.to_string(), port)
        }
        // Domain name
        0x03 => {
            let mut len_buf = [0u8; 1];
            stream.read_exact(&mut len_buf).await?;
            let len = len_buf[0] as usize;
            let mut domain = vec![0u8; len];
            stream.read_exact(&mut domain).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            (String::from_utf8(domain)?, port)
        }
        // IPv6
        0x04 => {
            let mut addr = [0u8; 16];
            stream.read_exact(&mut addr).await?;
            let mut port_buf = [0u8; 2];
            stream.read_exact(&mut port_buf).await?;
            let port = u16::from_be_bytes(port_buf);
            let ip = std::net::Ipv6Addr::from(addr);
            (ip.to_string(), port)
        }
        _ => {
            let reply = [0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err("unsupported address type".into());
        }
    };

    // --- Connect via Tor ----------------------------------------------------
    let tor_addr = (host.as_str(), port)
        .into_tor_addr()
        .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> {
            format!("invalid Tor address: {e}").into()
        })?;

    log_debug!("socks"," Connecting to {host}:{port} via Tor");
    let socks_start = std::time::Instant::now();
    let tor_stream = match tokio::time::timeout(
        std::time::Duration::from_secs(15),
        tor.connect(tor_addr),
    ).await {
        Ok(Ok(s)) => {
            log_debug!("socks"," Connected to {host}:{port} in {:?}", socks_start.elapsed());
            s
        }
        Ok(Err(e)) => {
            log_debug!("socks"," Failed to connect to {host}:{port} in {:?}: {e}", socks_start.elapsed());
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err(format!("Tor connect failed: {e}").into());
        }
        Err(_) => {
            log_debug!("socks"," Timed out connecting to {host}:{port} after 15s");
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err("Tor stream timed out after 15s".into());
        }
    };

    // Record the real path of the circuit this stream runs on, so the UI can
    // show the actual relays carrying AO3 traffic.
    capture_circuit_path(&tor_stream);

    // --- Success reply ------------------------------------------------------
    // VER | REP(0x00=success) | RSV | ATYP(IPv4) | BND.ADDR(0.0.0.0) | BND.PORT(0)
    let reply = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
    stream.write_all(&reply).await?;

    // --- Bidirectional copy -------------------------------------------------
    let (mut local_read, mut local_write) = stream.into_split();
    let (mut tor_read, mut tor_write) = tokio::io::split(tor_stream);

    let client_to_tor = tokio::io::copy(&mut local_read, &mut tor_write);
    let tor_to_client = tokio::io::copy(&mut tor_read, &mut local_write);

    // When either direction finishes (or errors), we're done.
    tokio::select! {
        _ = client_to_tor => {}
        _ = tor_to_client => {}
    }

    Ok(())
}

/// Capture the path of the circuit carrying `stream` into the process-global
/// slot read by `get_circuit_hops`.
///
/// This is the honest source: `tor-proto`'s `stream-ctrl` feature exposes the
/// stream's own tunnel handle, so every hop reported here is a relay arti
/// actually built this circuit through. Roles follow position (first = Guard,
/// last = Exit, anything between = Relay); countries come from arti's
/// embedded GeoIP database, or stay empty when an address has no entry —
/// never invented.
#[cfg(feature = "tor")]
fn capture_circuit_path(stream: &arti_client::DataStream) {
    use tor_linkspec::HasAddrs;
    use tor_proto::client::stream::ClientStreamCtrl;

    let Some(ctrl) = stream.client_stream_ctrl() else { return };
    let Some(tunnel) = ctrl.tunnel() else { return };
    // AO3 traffic uses plain single-circuit tunnels; `all_paths` returns one
    // entry for those (and one per leg for conflux, where the first is fine
    // as a representative path).
    let paths = tunnel.all_paths();
    let Some(path) = paths.first() else { return };
    let n_hops = path.n_hops();
    if n_hops == 0 {
        return;
    }

    let geoip = tor_geoip::GeoipDb::new_embedded();
    let hops = path
        .hops()
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let role = if i == 0 {
                "Guard"
            } else if i + 1 == n_hops {
                "Exit"
            } else {
                "Relay"
            };
            let ip = entry
                .as_chan_target()
                .and_then(|ct| ct.addrs().next())
                .map(|sa| sa.ip());
            super::circuit::CircuitHopInfo {
                role: role.to_string(),
                address: ip.map(|ip| ip.to_string()).unwrap_or_default(),
                country: ip
                    .and_then(|ip| geoip.lookup_country_code(ip))
                    .map(|cc| cc.to_string())
                    .unwrap_or_default(),
            }
        })
        .collect();
    super::circuit::set_current_circuit_hops(hops);
}
