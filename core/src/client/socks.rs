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
    let stream_id = super::circuit::next_stream_id();
    let tor_stream = match tokio::time::timeout(
        std::time::Duration::from_secs(15),
        tor.connect(tor_addr),
    ).await {
        Ok(Ok(s)) => {
            log_debug!("socks"," Connected to {host}:{port} in {:?}", socks_start.elapsed());
            s
        }
        Ok(Err(e)) => {
            // arti's top-level Display is generic ("failed to obtain exit
            // circuit"); the cause — no usable guards, circuit timeout,
            // stale directory — is only in the source chain.
            log_info!("socks"," Failed to connect to {host}:{port} in {:?}: {}", socks_start.elapsed(), error_chain(&e));
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err(format!("Tor connect failed: {e}").into());
        }
        Err(_) => {
            log_info!("socks"," Timed out connecting to {host}:{port} after 15s");
            let reply = [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
            stream.write_all(&reply).await?;
            return Err("Tor stream timed out after 15s".into());
        }
    };

    // Record the real path of the circuit this stream runs on, so the UI can
    // show the actual relays carrying AO3 traffic.
    capture_circuit_path(&tor_stream);
    // And the stream's own identity + timing, so each request-log row can
    // say which exit carried it (`circuit::current_stream`).
    let connect_ms = socks_start.elapsed().as_millis() as u64;
    let info = describe_stream(&tor_stream, stream_id, &format!("{host}:{port}"), connect_ms);
    let circ = info.circuit.clone();
    log_debug!("socks"," stream {} exit={} guard={} for {host}:{port}", circ, info.exit, info.guard);
    super::circuit::set_current_stream(info);
    let opened = std::time::Instant::now();

    // --- Success reply ------------------------------------------------------
    // VER | REP(0x00=success) | RSV | ATYP(IPv4) | BND.ADDR(0.0.0.0) | BND.PORT(0)
    let reply = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
    stream.write_all(&reply).await?;

    // --- Bidirectional copy -------------------------------------------------
    // The copy itself is tokio's, untouched; the readers are wrapped so
    // byte counts and first-byte times are observed as they pass.
    let (local_read, mut local_write) = stream.into_split();
    let (tor_read, mut tor_write) = tokio::io::split(tor_stream);

    let tx_bytes = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let rx_bytes = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let first_rx = Arc::new(std::sync::Mutex::new(None::<u64>));
    let mut local_read = Observed::new(local_read, Arc::clone(&tx_bytes), {
        move || super::circuit::note_stream_first_tx(stream_id, opened.elapsed().as_millis() as u64)
    });
    let mut tor_read = Observed::new(tor_read, Arc::clone(&rx_bytes), {
        let first_rx = Arc::clone(&first_rx);
        let circ = circ.clone();
        move || {
            let ms = opened.elapsed().as_millis() as u64;
            *first_rx.lock().unwrap() = Some(ms);
            log_debug!("socks"," stream {} first byte from exit at +{}ms", circ, ms);
            super::circuit::note_stream_first_rx(stream_id, ms);
        }
    });

    let client_to_tor = tokio::io::copy(&mut local_read, &mut tor_write);
    let tor_to_client = tokio::io::copy(&mut tor_read, &mut local_write);

    // When either direction finishes (or errors), we're done.
    tokio::select! {
        _ = client_to_tor => {}
        _ = tor_to_client => {}
    }

    log_debug!("socks"," stream {} closed after {}ms tx={} rx={} first_rx={}",
        circ, opened.elapsed().as_millis(),
        tx_bytes.load(std::sync::atomic::Ordering::Relaxed),
        rx_bytes.load(std::sync::atomic::Ordering::Relaxed),
        first_rx.lock().unwrap().map_or("never".to_string(), |ms| format!("+{ms}ms")));

    Ok(())
}

/// An `AsyncRead` that passes every poll straight through to the inner
/// reader, counting the bytes it yields and firing `on_first` once, on the
/// first byte. Nothing about the data or its timing is changed.
struct Observed<R> {
    inner: R,
    bytes: Arc<std::sync::atomic::AtomicU64>,
    on_first: Option<Box<dyn FnOnce() + Send>>,
}

impl<R> Observed<R> {
    fn new(inner: R, bytes: Arc<std::sync::atomic::AtomicU64>, on_first: impl FnOnce() + Send + 'static) -> Self {
        Observed { inner, bytes, on_first: Some(Box::new(on_first)) }
    }
}

impl<R: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for Observed<R> {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let res = std::pin::Pin::new(&mut this.inner).poll_read(cx, buf);
        let n = buf.filled().len() - before;
        if n > 0 {
            this.bytes.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
            if let Some(f) = this.on_first.take() {
                f();
            }
        }
        res
    }
}

/// Identity of the circuit carrying `stream`, from the same `stream-ctrl`
/// handle `capture_circuit_path` uses: arti's own circuit id and the RSA
/// fingerprints of the first (guard) and last (exit) hops. "?" where a
/// value is unavailable — never guessed.
#[cfg(feature = "tor")]
fn describe_stream(stream: &arti_client::DataStream, id: u64, target: &str, connect_ms: u64) -> super::circuit::StreamInfo {
    use tor_linkspec::HasRelayIds;
    use tor_proto::client::stream::ClientStreamCtrl;

    let mut info = super::circuit::StreamInfo {
        id, target: target.to_string(), connect_ms,
        circuit: "?".to_string(), exit: "?".to_string(), guard: "?".to_string(),
        ..Default::default()
    };
    let Some(ctrl) = stream.client_stream_ctrl() else { return info };
    let Some(tunnel) = ctrl.tunnel() else { return info };
    info.circuit = tunnel.unique_id().to_string();
    let paths = tunnel.all_paths();
    let Some(path) = paths.first() else { return info };
    let hops = path.hops();
    let fp = |entry: &tor_proto::client::circuit::PathEntry| -> String {
        entry
            .as_chan_target()
            .and_then(|ct| ct.rsa_identity().map(|id| id.to_string()))
            .map(|s| s.trim_start_matches('$').chars().take(8).collect::<String>())
            .unwrap_or_else(|| "?".to_string())
    };
    if let Some(first) = hops.first() {
        info.guard = fp(first);
    }
    if let Some(last) = hops.last() {
        info.exit = fp(last);
    }
    info
}

/// An error with every `source()` beneath it, outermost first.
#[cfg(feature = "tor")]
pub(super) fn error_chain(e: &dyn std::error::Error) -> String {
    let mut out = e.to_string();
    let mut source = e.source();
    while let Some(cause) = source {
        out.push_str(" <- ");
        out.push_str(&cause.to_string());
        source = cause.source();
    }
    out
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
