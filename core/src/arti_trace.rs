//! Bridge from arti's `tracing` output into the debug log.
//!
//! arti never returns its most useful diagnostics as errors: a guard being
//! disabled, circuit builds timing out, a directory store stuck read-only,
//! a bootstrap stalling — all of it is only ever *logged*, through
//! `tracing`. With no subscriber installed those events are discarded, and
//! a Tor failure reaches us as nothing more than "connect failed". This
//! installs a process-wide subscriber that writes arti's events to the
//! same debug log as everything else, under the tag "arti".
//!
//! Scope is deliberately narrow: only `tor_*` / `arti_*` targets, INFO and
//! up — plus DEBUG for the guard and circuit managers, which is where
//! guard status changes and per-circuit build failures are reported.

use std::fmt::Write as _;

use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::filter::{LevelFilter, Targets};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::Layer;

/// Install the bridge. Idempotent: the global subscriber can only be set
/// once per process, and later calls (every unlock re-runs logging init)
/// are no-ops.
pub(crate) fn install() {
    static INSTALLED: std::sync::Once = std::sync::Once::new();
    INSTALLED.call_once(|| {
        let targets = Targets::new()
            .with_target("arti_client", LevelFilter::INFO)
            .with_target("tor_dirmgr", LevelFilter::INFO)
            .with_target("tor_chanmgr", LevelFilter::INFO)
            .with_target("tor_proto", LevelFilter::INFO)
            .with_target("tor_persist", LevelFilter::INFO)
            .with_target("tor_guardmgr", LevelFilter::DEBUG)
            .with_target("tor_circmgr", LevelFilter::DEBUG);
        let subscriber = tracing_subscriber::registry().with(DebugLogLayer.with_filter(targets));
        // Fails only if something else already claimed the global slot —
        // nothing to do about that, and nothing lost relative to before.
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

struct DebugLogLayer;

impl<S: Subscriber> Layer<S> for DebugLogLayer {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let meta = event.metadata();
        let level = match *meta.level() {
            Level::ERROR => "ERROR",
            Level::WARN => "WARN",
            Level::INFO => "INFO",
            _ => "DEBUG",
        };
        let mut fields = FieldText(String::new());
        event.record(&mut fields);
        crate::dlog(level, "arti", &format!("{}: {}", meta.target(), fields.0));
    }
}

/// Flattens an event's fields to text: the message first, then `key=value`.
struct FieldText(String);

impl Visit for FieldText {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            let _ = write!(self.0, "{value:?}");
        } else {
            let _ = write!(self.0, " {}={value:?}", field.name());
        }
    }
}
