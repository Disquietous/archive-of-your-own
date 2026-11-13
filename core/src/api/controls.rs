//! Controls over the bridge (design/source-controls-plan.md): what the
//! user can do with one row right now, resolved here from the row, its
//! source's capabilities and that source's account state. Synchronous and
//! cache-only — the UI calls these on every render. The one write every
//! source shapes the same way, `set_reaction`, dispatches to the adapter.

use super::*;
use crate::source::{Gate, Reaction, ReactionControl, ReactionOutcome, ReactionShape, Source, TagControls,
                    UserControls, UserList, WorkControls};

fn reaction_control(source: &Arc<dyn Source>, s: &Storage, work_id: u64) -> ReactionControl {
    let gate = source.reaction_gate(s.signed_in_at(source.id()));
    match source.capabilities().reaction {
        ReactionShape::None => ReactionControl::None,
        ReactionShape::Kudos => {
            let given = s.get_kudos_given().map(|ids| ids.contains(&work_id)).unwrap_or(false);
            ReactionControl::Kudos { given, gate }
        }
        ReactionShape::StarRating { max } => {
            let mine = s.get_work_reaction(work_id).ok().flatten();
            let average = s.field_id(source.id(), crate::source::STAT_SITE_RATING)
                .and_then(|field| s.get_work_stat_num(work_id, field).ok().flatten())
                .filter(|avg| *avg > 0.0)
                .map(|avg| format!("{:.1}", avg.min(max as f64)));
            ReactionControl::StarRating { max, mine, average, gate }
        }
    }
}

/// A sign-in gate: hidden when the source has no such control, disabled
/// with `reason` until the source's account is signed in.
fn account_gate(shown: bool, signed_in: bool, reason: &str) -> Gate {
    Gate::when(shown, signed_in, reason)
}

pub(super) fn resolve_work_controls(s: &Storage, registry: &crate::source::SourceRegistry, work_id: u64) -> Option<WorkControls> {
        let external = s.work_ref(work_id)?;
        let source = registry.by_id(&external.source)?;
        let caps = source.capabilities();
        let signed_in = s.signed_in_at(&caps.id);
        Some(WorkControls {
            source: caps.id.clone(),
            site_url: if external.url.is_empty() { None } else { Some(external.url.clone()) },
            reaction: reaction_control(&source, &s, work_id),
            discussion: caps.discussion,
            chapter_comments: caps.chapter_comments,
            subscribe: account_gate(caps.subscriptions, signed_in, "Sign in to subscribe"),
            remote_bookmark: account_gate(caps.remote_bookmarks, signed_in, "Sign in to bookmark"),
            post: source.post_gate(signed_in),
            vocabulary: caps.vocabulary.clone(),
        })
}

pub(super) fn resolve_user_controls(s: &Storage, registry: &crate::source::SourceRegistry, user_id: u64) -> Option<UserControls> {
        use crate::user_fields::UserField as F;
        let user = s.get_user(user_id as i64)?;
        let source = registry.by_id(&user.source)?;
        let caps = source.capabilities();
        let signed_in = s.signed_in_at(&caps.id);
        let mut lists = vec![UserList::Works];
        if caps.remote_bookmarks { lists.push(UserList::Bookmarks) }
        if caps.collections { lists.push(UserList::Collections) }
        Some(UserControls {
            source: caps.id.clone(),
            site_url: user.field(F::ProfileUrl).filter(|u| !u.is_empty()).map(str::to_string),
            subscribe: account_gate(caps.subscriptions, signed_in, "Sign in to subscribe"),
            moderation: account_gate(caps.user_moderation, signed_in, "Sign in to block or mute"),
            lists,
            author_listings: caps.author_listings,
            username_is_key: caps.username_is_key,
            vocabulary: caps.vocabulary.clone(),
        })
}

pub(super) fn resolve_tag_controls(registry: &crate::source::SourceRegistry, source_id: &str, tag: &str) -> Option<TagControls> {
    let source = registry.by_id(source_id)?;
    let caps = source.capabilities();
    Some(TagControls { source: caps.id.clone(), site_url: source.tag_url(tag), vocabulary: caps.vocabulary.clone() })
}

#[uniffi::export]
impl AO3App {
    /// The controls for one work, or None for an unknown row or source.
    pub fn work_controls(&self, work_id: u64) -> Option<WorkControls> {
        resolve_work_controls(&self.storage.blocking_lock(), &self.sources, work_id)
    }

    /// The controls for one user (author or commenter).
    pub fn user_controls(&self, user_id: u64) -> Option<UserControls> {
        resolve_user_controls(&self.storage.blocking_lock(), &self.sources, user_id)
    }

    /// The controls for a tag on a source; None for an unknown source.
    pub fn tag_controls(&self, source_id: String, tag: String) -> Option<TagControls> {
        resolve_tag_controls(&self.sources, &source_id, &tag)
    }

    /// Whether a stored sign-in at `source_id` still carries its login.
    pub fn is_signed_in(&self, source_id: String) -> bool {
        self.storage.blocking_lock().signed_in_at(&source_id)
    }

    /// Send the reader's reaction to the work's source and record what it
    /// accepted: kudos as given (permanent), a star value as the reader's
    /// own rating (replaced or cleared). `op_id`: request-tracking standard.
    pub async fn set_reaction(&self, work_id: u64, reaction: Reaction, op_id: Option<u64>) -> Result<ReactionOutcome, AO3Error> {
        let registry = self.sources.clone();
        self.run_on_runtime_for(op_id, move |client, storage| async move {
            let (source, external) = {
                let c = client.read().await;
                let s = storage.lock().await;
                seed_posting_credentials(&c, &s);
                source_for_work(&s, &registry, work_id)?
            };
            // A duplicate kudos is answered "already left" and a rating
            // re-sent is the same rating, so a full retry after a circuit
            // rotation never double-applies — safe for every failure kind.
            let src = source.clone();
            let external = Arc::new(external);
            let outcome = with_recovery_as(client.clone(), storage.clone(),
                op_id.unwrap_or_else(crate::events::next_op_id),
                OpKind::Kudos, RetrySafety::Idempotent,
                move |_client| {
                    let (src, external) = (src.clone(), external.clone());
                    async move { src.react(&external, reaction).await.map_err(AO3Error::from) }
                }).await?;
            let c = client.read().await;
            let s = storage.lock().await;
            persist_posting_credentials(&c, &s);
            if outcome.accepted {
                match reaction {
                    Reaction::Kudos => log_db("mark_kudos_given", s.mark_kudos_given(work_id)),
                    Reaction::Stars { .. } => match outcome.value {
                        Some(v) => log_db("set_work_reaction", s.set_work_reaction(work_id, v)),
                        None => log_db("clear_work_reaction", s.clear_work_reaction(work_id)),
                    },
                    Reaction::Clear => log_db("clear_work_reaction", s.clear_work_reaction(work_id)),
                }
            }
            Ok(outcome)
        }).await
    }

    /// Every work the reader has rated, with the value.
    pub fn get_work_reactions(&self) -> Result<Vec<UWorkReaction>, AO3Error> {
        let s = self.storage.blocking_lock();
        Ok(s.get_work_reactions().map_err(AO3Error::from)?
            .into_iter().map(|(work_id, value)| UWorkReaction { work_id, value }).collect())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UWorkReaction {
    pub work_id: u64,
    pub value: u8,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AO3User, ExternalRef};
    use crate::source::{DiscussionShape, Gate, ReactionControl, UserList};

    async fn registry() -> crate::source::SourceRegistry {
        let client = Arc::new(tokio::sync::RwLock::new(AO3Client::new_direct().await.unwrap()));
        super::super::sources::registry(client)
    }

    #[tokio::test]
    async fn work_controls_follow_the_shape_and_the_stored_row() {
        let reg = registry().await;
        let s = Storage::open_in_memory("k").unwrap();
        let rated = s.ensure_work_stub(&ExternalRef { source: "mockrated".into(), external_id: "1".into(), url: "https://rated.mock/story/1".into() }, "t").unwrap();
        let c = resolve_work_controls(&s, &reg, rated).unwrap();
        assert_eq!(c.site_url.as_deref(), Some("https://rated.mock/story/1"));
        assert_eq!(c.reaction, ReactionControl::StarRating { max: 5, mine: None, average: None, gate: Gate::Enabled });

        // The site average rides on the control, one decimal.
        let field = s.ensure_field("mockrated", crate::source::STAT_SITE_RATING, "Rating", "num", 1).unwrap();
        s.set_work_stats(rated, &[crate::storage::WorkStat { field_id: field, num_value: Some(4.14), text_value: None }]).unwrap();
        assert!(matches!(resolve_work_controls(&s, &reg, rated).unwrap().reaction,
                         ReactionControl::StarRating { average: Some(ref a), .. } if a == "4.1"));
        assert_eq!(c.discussion, DiscussionShape::Reviews);
        assert!(c.chapter_comments);
        assert_eq!(c.subscribe, Gate::Hidden);
        assert_eq!(c.remote_bookmark, Gate::Hidden);
        assert_eq!(c.vocabulary.refresh, "Refresh from Rated Mock");

        // The row remembers the reader's own value; clearing forgets it.
        s.set_work_reaction(rated, 4).unwrap();
        assert!(matches!(resolve_work_controls(&s, &reg, rated).unwrap().reaction, ReactionControl::StarRating { mine: Some(4), .. }));
        s.set_work_reaction(rated, 2).unwrap();
        assert_eq!(s.get_work_reactions().unwrap(), vec![(rated, 2)]);
        s.clear_work_reaction(rated).unwrap();
        assert!(matches!(resolve_work_controls(&s, &reg, rated).unwrap().reaction, ReactionControl::StarRating { mine: None, .. }));

        // An AO3 row: kudos open to guests, subscribe and bookmark wait for a sign-in.
        let ao3 = s.ensure_work_stub(&ExternalRef::ao3("4242", "https://archiveofourown.org/works/4242"), "t").unwrap();
        let c = resolve_work_controls(&s, &reg, ao3).unwrap();
        assert_eq!(c.reaction, ReactionControl::Kudos { given: false, gate: Gate::Enabled });
        assert_eq!(c.subscribe, Gate::Disabled { reason: "Sign in to subscribe".to_string() });
        assert_eq!(c.remote_bookmark, Gate::Disabled { reason: "Sign in to bookmark".to_string() });
        assert_eq!(c.site_url.as_deref(), Some("https://archiveofourown.org/works/4242"));
        assert_eq!(c.vocabulary.site_short, "AO3");
        s.mark_kudos_given(ao3).unwrap();
        assert_eq!(resolve_work_controls(&s, &reg, ao3).unwrap().reaction, ReactionControl::Kudos { given: true, gate: Gate::Enabled });
        assert!(resolve_work_controls(&s, &reg, 999_999).is_none());
    }

    #[tokio::test]
    async fn user_and_tag_controls() {
        let reg = registry().await;
        let s = Storage::open_in_memory("k").unwrap();
        let ao3_user = s.record_user(&AO3User::ao3("quill", "quill", Some("https://archiveofourown.org/users/quill".to_string()), None)).unwrap();
        let c = resolve_user_controls(&s, &reg, ao3_user as u64).unwrap();
        assert_eq!(c.lists, vec![UserList::Works, UserList::Bookmarks, UserList::Collections]);
        assert!(c.username_is_key && c.author_listings);
        assert_eq!(c.moderation, Gate::Disabled { reason: "Sign in to block or mute".to_string() });
        assert_eq!(c.site_url.as_deref(), Some("https://archiveofourown.org/users/quill"));

        let sh_user = s.record_user(&AO3User {
            source: "scribblehub".into(), id: "51230".into(), username: "quill".into(),
            profile_url: Some("https://www.scribblehub.com/profile/51230/quill/".into()), avatar_url: None,
        }).unwrap();
        let c = resolve_user_controls(&s, &reg, sh_user as u64).unwrap();
        assert_eq!(c.lists, vec![UserList::Works]);
        assert_eq!(c.moderation, Gate::Hidden);
        assert_eq!(c.subscribe, Gate::Hidden);
        assert!(!c.username_is_key);

        let t = resolve_tag_controls(&reg, "ao3", "Hurt/Comfort").unwrap();
        assert_eq!(t.site_url.as_deref(), Some("https://archiveofourown.org/tags/Hurt*s*Comfort/works"));
        assert!(resolve_tag_controls(&reg, "scribblehub", "x").unwrap().site_url.is_none());
        assert!(resolve_tag_controls(&reg, "nope", "x").is_none());
    }
}
