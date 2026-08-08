use super::*;

#[uniffi::export]
impl AO3App {
    #[uniffi::constructor]
    pub fn new(db_path: String, db_passphrase: String) -> Result<Self, AO3Error> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| AO3Error::Network { message: e.to_string() })?;

        let client = runtime.block_on(async {
            AO3Client::new_direct().await
        }).map_err(AO3Error::from)?;

        let storage = Storage::open(&db_path, &db_passphrase)
            .map_err(AO3Error::from)?;

        let storage = Arc::new(Mutex::new(storage));
        crate::init_logging(&db_path, &db_passphrase);

        let state_dir = std::path::Path::new(&db_path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| db_path.clone());

        Ok(AO3App {
            client: Arc::new(tokio::sync::RwLock::new(client)),
            storage,
            state_dir,
            timeout_secs: Arc::new(std::sync::atomic::AtomicU64::new(30)),
            active_tasks: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            next_task_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
            tor_connected: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            socks_port: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            _runtime: Arc::new(runtime),
            progress_handles: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            census_cycle_used: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    // -- Tor connection --

    pub async fn connect_tor(&self) -> Result<(), AO3Error> {
        #[cfg(feature = "tor")]
        {
            let state_dir = self.state_dir.clone();
            let runtime = self._runtime.clone();
            let client_ref = self.client.clone();

            // Spawn onto our tokio runtime so arti has a live reactor
            let new_client = runtime.spawn(async move {
                AO3Client::new_tor_with_dir(&state_dir).await
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Tor task panicked: {e}") })?
            .map_err(AO3Error::from)?;

            let timeout = self.timeout_secs.clone();
            let client_ref2 = client_ref.clone();
            let tor_connected = self.tor_connected.clone();
            let socks_port = self.socks_port.clone();
            runtime.spawn(async move {
                let mut client = client_ref2.write().await;
                let secs = timeout.load(std::sync::atomic::Ordering::Relaxed);
                new_client.set_timeout(secs);
                tor_connected.store(new_client.is_tor(), std::sync::atomic::Ordering::Relaxed);
                socks_port.store(new_client.socks_port().unwrap_or(0) as u32, std::sync::atomic::Ordering::Relaxed);
                *client = new_client;
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Failed to update client: {e}") })?;

            Ok(())
        }
        #[cfg(not(feature = "tor"))]
        {
            Err(AO3Error::Network { message: "Tor support not compiled in".to_string() })
        }
    }

    pub async fn new_circuit(&self) -> Result<(), AO3Error> {
        #[cfg(feature = "tor")]
        {
            let client_ref = self.client.clone();
            let runtime = self._runtime.clone();
            let tor_connected = self.tor_connected.clone();
            let socks_port = self.socks_port.clone();
            runtime.spawn(async move {
                let mut client = client_ref.write().await;
                let result = client.new_circuit().await;
                tor_connected.store(client.is_tor(), std::sync::atomic::Ordering::Relaxed);
                socks_port.store(client.socks_port().unwrap_or(0) as u32, std::sync::atomic::Ordering::Relaxed);
                result
            })
            .await
            .map_err(|e| AO3Error::Network { message: format!("Circuit task failed: {e}") })?
            .map_err(AO3Error::from)?;
            Ok(())
        }
        #[cfg(not(feature = "tor"))]
        {
            Err(AO3Error::Network { message: "Tor support not compiled in".to_string() })
        }
    }

    pub async fn disconnect_tor(&self) -> Result<(), AO3Error> {
        let client_ref = self.client.clone();
        let runtime = self._runtime.clone();
        let tor_connected = self.tor_connected.clone();
        let socks_port = self.socks_port.clone();
        runtime.spawn(async move {
            let mut client = client_ref.write().await;
            let result = client.disconnect_tor();
            tor_connected.store(client.is_tor(), std::sync::atomic::Ordering::Relaxed);
            socks_port.store(client.socks_port().unwrap_or(0) as u32, std::sync::atomic::Ordering::Relaxed);
            result
        })
        .await
        .map_err(|e| AO3Error::Network { message: format!("Disconnect failed: {e}") })?
        .map_err(AO3Error::from)?;
        Ok(())
    }

    pub fn set_request_timeout(&self, seconds: u64) {
        self.timeout_secs.store(seconds, std::sync::atomic::Ordering::Relaxed);
        // Never block the caller (typically the main thread) on the client
        // lock — apply asynchronously when it's contended.
        if let Ok(client) = self.client.try_read() {
            client.set_timeout(seconds);
        } else {
            let client_ref = self.client.clone();
            self._runtime.spawn(async move {
                client_ref.read().await.set_timeout(seconds);
            });
        }
    }

    pub fn get_request_timeout(&self) -> u64 {
        self.timeout_secs.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn cancel_request(&self) {
        if let Ok(mut tasks) = self.active_tasks.try_lock() {
            for (_, handle) in tasks.drain() {
                handle.abort();
            }
        }
    }

    pub fn get_fetch_progress(&self, operation: String) -> UFetchProgress {
        use crate::client::FetchStatus;
        let handles = self.progress_handles.lock().unwrap();
        let p = handles.get(&operation)
            .map(|h| h.lock().unwrap().clone())
            .unwrap_or(FetchProgress {
                bytes_received: 0,
                total_bytes: None,
                status: FetchStatus::Idle,
            });
        UFetchProgress {
            bytes_received: p.bytes_received,
            total_bytes: p.total_bytes.map(|t| t as i64).unwrap_or(-1),
            status: match p.status {
                FetchStatus::Idle => "idle",
                FetchStatus::Connecting => "connecting",
                FetchStatus::Downloading => "downloading",
                FetchStatus::Complete => "complete",
                FetchStatus::Failed => "failed",
            }.to_string(),
        }
    }

    pub fn is_request_active(&self) -> bool {
        self.active_tasks.try_lock().map_or(false, |t| !t.is_empty())
    }

    pub fn is_tor_connected(&self) -> bool {
        self.tor_connected.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Return the local SOCKS5 proxy port used by the Tor transport.
    /// Returns 0 if Tor is not connected.
    pub fn get_socks_port(&self) -> u16 {
        self.socks_port.load(std::sync::atomic::Ordering::Relaxed) as u16
    }

    /// Inject cookies into the reqwest cookie jar (e.g. cf_clearance from
    /// WKWebView). Each string should be in "name=value" format.
    /// Runs on the runtime so the caller (typically the main thread) never
    /// blocks on the client lock.
    pub fn inject_cookies(&self, cookies: Vec<String>) {
        let client_ref = self.client.clone();
        self._runtime.spawn(async move {
            let cf_prefixes = ["cf_clearance=", "__cf_bm=", "_cfuvid=", "cf_chl_"];
            let client = client_ref.read().await;
            let mut injected = 0;
            for cookie in &cookies {
                if cookie.is_empty() { continue; }
                let is_cf = cf_prefixes.iter().any(|p| cookie.contains(p));
                if is_cf {
                    client.set_session_cookies(cookie);
                    injected += 1;
                    log_info!("cookies", " Injected CF cookie: {}", &cookie[..cookie.len().min(60)]);
                }
            }
            let verify = client.get_session_cookies();
            log_info!("cookies", " After inject: {} CF cookies added, jar has {} chars, cf_clearance={}",
                injected, verify.len(), verify.contains("cf_clearance"));
        });
    }

    /// The real path of the Tor circuit most recently used for AO3 traffic.
    ///
    /// The SOCKS bridge captures each stream's actual circuit via
    /// `tor-proto`'s `stream-ctrl` API the moment `tor.connect()` succeeds,
    /// so every hop here is a relay arti genuinely built the path through:
    /// role by position (Guard/Relay/Exit), the relay's IP, and its country
    /// resolved from arti's embedded GeoIP database (empty when unknown —
    /// never invented). Returns an empty list until the first stream has run
    /// on the current Tor client, and after disconnect or circuit rotation
    /// until the replacement circuit carries traffic; the UIs show a generic
    /// no-identity diagram for that state.
    pub fn get_circuit_hops(&self) -> Vec<UCircuitHop> {
        crate::client::current_circuit_hops()
            .into_iter()
            .map(|h| UCircuitHop {
                role: h.role,
                address: h.address,
                country: h.country,
            })
            .collect()
    }

    // -- Network operations --

    pub async fn check_circuit_health(&self) -> Result<bool, AO3Error> {
        self.run_on_runtime(|client, _storage| async move {
            let c = client.read().await;
            match tokio::time::timeout(
                std::time::Duration::from_secs(20),
                c.fetch_health_check(),
            ).await {
                Ok(Ok(status)) => {
                    log_info!("health", "Circuit health check: status {}", status);
                    Ok(status >= 200 && status < 400)
                }
                Ok(Err(e)) => {
                    log_info!("health", "Circuit health check failed: {}", e);
                    Ok(false)
                }
                Err(_) => {
                    log_info!("health", "Circuit health check timed out");
                    Ok(false)
                }
            }
        }).await
    }

    /// Requests currently in flight (started but not yet resolved), newest last.
    pub fn get_active_requests(&self) -> Vec<UActiveRequest> {
        let now = crate::client::now_ms();
        crate::client::active_requests_snapshot().into_iter().map(|r| UActiveRequest {
            started_ms: r.started_at_ms as i64,
            method: r.method,
            url: r.url,
            elapsed_ms: now.saturating_sub(r.started_at_ms) as i64,
        }).collect()
    }
}
