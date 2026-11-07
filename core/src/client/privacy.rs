//! The privacy policy: the one rule every request passes through.
//!
//! The app never sends to AO3 unprotected unless the user chose to. Which
//! protection satisfies that is the mode: Tor (the app runs the tunnel),
//! the user's own VPN (the system runs it; the app verifies it carries the
//! default route), or none (an explicit opt-out). Process-wide, like the
//! old Tor requirement it replaces, so no client swap can carry a stale
//! copy; starts as Tor so the app fails closed until told otherwise.

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Mutex;

pub use super::vpn::{VpnFingerprint, VpnStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PrivacyMode {
    /// Requests go through the app's own Tor client, or not at all.
    Tor,
    /// Requests go out directly, but only while the registered VPN carries
    /// the default route (unless `vpn_required` is off).
    Vpn,
    /// Requests go out directly. The user opted out of protection.
    Open,
}

/// Why a request was refused before it was sent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum NetworkRefusal {
    /// Mode is Tor and the client has no Tor transport.
    TorNotConnected,
    /// Mode is VPN, it is required, and verification did not match.
    VpnNotVerified { status: VpnStatus },
    /// The mock archive is on and has no page for the request.
    MockUnserved,
}

static MODE: AtomicU8 = AtomicU8::new(0);
static VPN_REQUIRED: AtomicBool = AtomicBool::new(true);
static FINGERPRINT: Mutex<Option<VpnFingerprint>> = Mutex::new(None);
static LAST_STATUS: Mutex<Option<VpnStatus>> = Mutex::new(None);

fn mode_from(v: u8) -> PrivacyMode {
    match v {
        1 => PrivacyMode::Vpn,
        2 => PrivacyMode::Open,
        _ => PrivacyMode::Tor,
    }
}

pub fn set_privacy_mode(mode: PrivacyMode) {
    MODE.store(mode as u8, Ordering::Relaxed);
}

pub fn privacy_mode() -> PrivacyMode {
    mode_from(MODE.load(Ordering::Relaxed))
}

/// Whether VPN mode blocks requests while the VPN is not verified. Off
/// means VPN mode behaves as Open while still reporting the VPN's state.
pub fn set_vpn_required(required: bool) {
    VPN_REQUIRED.store(required, Ordering::Relaxed);
}

pub fn vpn_required() -> bool {
    VPN_REQUIRED.load(Ordering::Relaxed)
}

pub fn set_vpn_fingerprint(fp: Option<VpnFingerprint>) {
    *FINGERPRINT.lock().unwrap_or_else(|e| e.into_inner()) = fp;
    *LAST_STATUS.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

pub fn vpn_fingerprint() -> Option<VpnFingerprint> {
    FINGERPRINT.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Capture a fingerprint from the network as it is now and make it the
/// registered one.
pub fn register_vpn(label: &str) -> Result<VpnFingerprint, crate::error::AppError> {
    let facts = super::vpn::observe()?;
    let fp = super::vpn::capture(label, &facts, super::now_ms())?;
    set_vpn_fingerprint(Some(fp.clone()));
    Ok(fp)
}

/// The VPN's state right now, by local inspection. Microseconds; no I/O
/// beyond two sysctls and the resolver config.
pub fn vpn_status() -> VpnStatus {
    let Some(fp) = vpn_fingerprint() else { return VpnStatus::NotRegistered };
    match super::vpn::observe() {
        Ok(facts) => super::vpn::verify(&fp, &facts),
        Err(e) => VpnStatus::Unknown { message: e.to_string() },
    }
}

/// Re-check the VPN and say whether its state differs from the last
/// check. Callers emit the change event; the check itself never does, so
/// the per-request gate stays silent.
pub fn refresh_vpn_status() -> (VpnStatus, bool) {
    let status = vpn_status();
    let mut last = LAST_STATUS.lock().unwrap_or_else(|e| e.into_inner());
    let changed = last.as_ref() != Some(&status);
    *last = Some(status.clone());
    (status, changed)
}

/// The gate decision for one request. Pure: the VPN status is only read
/// when the mode needs it.
pub(crate) fn decide(
    mode: PrivacyMode,
    vpn_required: bool,
    is_tor: bool,
    vpn_status: impl FnOnce() -> VpnStatus,
) -> Result<(), NetworkRefusal> {
    match mode {
        PrivacyMode::Tor if is_tor => Ok(()),
        PrivacyMode::Tor => Err(NetworkRefusal::TorNotConnected),
        PrivacyMode::Vpn if !vpn_required => Ok(()),
        PrivacyMode::Vpn => match vpn_status() {
            VpnStatus::Matched => Ok(()),
            status => Err(NetworkRefusal::VpnNotVerified { status }),
        },
        PrivacyMode::Open => Ok(()),
    }
}

/// May a request go out on a client whose transport is (or isn't) Tor?
pub fn gate(is_tor: bool) -> Result<(), NetworkRefusal> {
    decide(privacy_mode(), vpn_required(), is_tor, || refresh_vpn_status().0)
}

/// Label for the request log's transport column when the request did not
/// go through a Tor stream.
pub(crate) fn transport_label() -> Option<String> {
    label_for(privacy_mode(), vpn_fingerprint().as_ref())
}

fn label_for(mode: PrivacyMode, fp: Option<&VpnFingerprint>) -> Option<String> {
    match mode {
        PrivacyMode::Tor => None,
        PrivacyMode::Vpn => Some(match fp {
            Some(fp) => format!("vpn:{}", fp.label),
            None => "vpn:unregistered".to_string(),
        }),
        PrivacyMode::Open => Some("open".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fp() -> VpnFingerprint {
        VpnFingerprint {
            label: "NordVPN".into(),
            tunnel_kind: "utun".into(),
            subnet: "10.5.0.2/16".into(),
            dns: vec![],
            captured_at_ms: 0,
        }
    }

    #[test]
    fn tor_mode_needs_a_tor_transport() {
        assert_eq!(decide(PrivacyMode::Tor, true, true, || unreachable!()), Ok(()));
        assert_eq!(decide(PrivacyMode::Tor, true, false, || unreachable!()), Err(NetworkRefusal::TorNotConnected));
        // Tor mode never consults the VPN, even on a Tor transport.
        assert_eq!(decide(PrivacyMode::Tor, false, false, || VpnStatus::Matched), Err(NetworkRefusal::TorNotConnected));
    }

    #[test]
    fn vpn_mode_needs_a_match_unless_not_required() {
        assert_eq!(decide(PrivacyMode::Vpn, true, false, || VpnStatus::Matched), Ok(()));
        assert_eq!(
            decide(PrivacyMode::Vpn, true, false, || VpnStatus::NoTunnel),
            Err(NetworkRefusal::VpnNotVerified { status: VpnStatus::NoTunnel })
        );
        assert_eq!(
            decide(PrivacyMode::Vpn, true, false, || VpnStatus::NotRegistered),
            Err(NetworkRefusal::VpnNotVerified { status: VpnStatus::NotRegistered })
        );
        assert_eq!(decide(PrivacyMode::Vpn, false, false, || unreachable!()), Ok(()));
    }

    #[test]
    fn open_mode_passes_everything() {
        assert_eq!(decide(PrivacyMode::Open, true, false, || unreachable!()), Ok(()));
        assert_eq!(decide(PrivacyMode::Open, true, true, || unreachable!()), Ok(()));
    }

    #[test]
    fn mode_round_trips_and_defaults_to_tor() {
        assert_eq!(mode_from(0), PrivacyMode::Tor);
        assert_eq!(mode_from(PrivacyMode::Vpn as u8), PrivacyMode::Vpn);
        assert_eq!(mode_from(PrivacyMode::Open as u8), PrivacyMode::Open);
        assert_eq!(mode_from(200), PrivacyMode::Tor);
    }

    #[test]
    fn transport_label_names_the_vpn() {
        assert_eq!(label_for(PrivacyMode::Tor, Some(&fp())), None);
        assert_eq!(label_for(PrivacyMode::Vpn, Some(&fp())).as_deref(), Some("vpn:NordVPN"));
        assert_eq!(label_for(PrivacyMode::Vpn, None).as_deref(), Some("vpn:unregistered"));
        assert_eq!(label_for(PrivacyMode::Open, None).as_deref(), Some("open"));
    }
}
