use scraper::{Html, Selector, ElementRef};

use crate::error::AppError;
use crate::models::*;

use super::{sel, text};

/// Parse AO3's subscriptions page to extract subscription entries.
///
/// Each subscription is an `li` or `dl` element containing links that indicate
/// the subscription type via URL pattern:
/// - `/users/{name}/pseuds` or `/users/{name}` => author subscription
/// - `/works/{id}` => work subscription
/// - `/series/{id}` => series subscription
/// The work page's subscribe form (form#new_subscription): where to POST,
/// whether the user is currently subscribed (the form flips into a delete
/// with the subscription id in its action), and the CSRF token to submit.
/// None when logged out — AO3 renders no subscription form for guests.
pub struct SubscriptionForm {
    pub action: String,
    pub subscribed: bool,
    pub token: String,
    pub subscribable_id: String,
    pub subscribable_type: String,
}

pub fn parse_work_subscription_form(html: &str) -> Option<SubscriptionForm> {
    let doc = Html::parse_document(html);
    let form = doc.select(&sel("form#new_subscription")).next()?;
    let action = form.value().attr("action")?.to_string();
    let token = form.select(&sel("input[name='authenticity_token']")).next()
        .and_then(|i| i.value().attr("value"))
        .map(str::to_string)
        .or_else(|| doc.select(&sel("meta[name='csrf-token']")).next()
            .and_then(|m| m.value().attr("content"))
            .map(str::to_string))?;
    let subscribed = form.select(&sel("input[name='_method']")).next()
        .and_then(|i| i.value().attr("value")) == Some("delete");
    let subscribable_id = form.select(&sel("input[name='subscription[subscribable_id]']")).next()
        .and_then(|i| i.value().attr("value")).unwrap_or("").to_string();
    let subscribable_type = form.select(&sel("input[name='subscription[subscribable_type]']")).next()
        .and_then(|i| i.value().attr("value")).unwrap_or("Work").to_string();
    Some(SubscriptionForm { action, subscribed, token, subscribable_id, subscribable_type })
}

// ---------------------------------------------------------------------------
// Search form parser — extracts form structure from /works/search?edit_search=true
// ---------------------------------------------------------------------------

pub fn parse_search_form(html: &str) -> Result<SearchForm, AppError> {
    let doc = Html::parse_document(html);
    let mut fields = Vec::new();
    let mut seen_names = std::collections::HashSet::new();

    // Find the main search form: <form id="new_work_search">
    let form_sel = sel("form#new_work_search");
    let form = doc.select(&form_sel).next()
        .ok_or_else(|| AppError::ElementNotFound("search form #new_work_search".to_string()))?;

    // Iterate <dd> elements — each contains one field or field group
    let dd_sel = sel("dd");
    let dt_sel = sel("dt");
    let dts: Vec<ElementRef> = form.select(&dt_sel).collect();
    let dds: Vec<ElementRef> = form.select(&dd_sel).collect();

    for (i, dd) in dds.iter().enumerate() {
        // Get the matching <dt> label
        let dt_label = if i < dts.len() {
            text(&dts[i]).trim_end_matches('?').trim().to_string()
        } else {
            String::new()
        };

        // Check what's inside this <dd>
        // 1. Text input
        let input_sel = sel("input[type='text'][name^='work_search']");
        if let Some(input) = dd.select(&input_sel).next() {
            let name = input.value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let id = input.value().attr("id").unwrap_or("");
                let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                fields.push(FormField {
                    name,
                    label,
                    field_type: FormFieldType::Text { placeholder: String::new() },
                });
                continue;
            }
        }

        // 2. Select dropdown
        let select_sel = sel("select[name^='work_search']");
        if let Some(select) = dd.select(&select_sel).next() {
            let name = select.value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let id = select.value().attr("id").unwrap_or("");
                let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                let option_sel = sel("option");
                let options: Vec<FormOption> = select.select(&option_sel).map(|opt| {
                    FormOption {
                        value: opt.value().attr("value").unwrap_or("").to_string(),
                        label: text(&opt),
                        selected: opt.value().attr("selected").is_some(),
                    }
                }).collect();
                fields.push(FormField {
                    name,
                    label,
                    field_type: FormFieldType::Select { options },
                });
                continue;
            }
        }

        // 3. Radio button group
        let radio_sel = sel("input[type='radio'][name^='work_search']");
        let radios: Vec<ElementRef> = dd.select(&radio_sel).collect();
        if !radios.is_empty() {
            let name = radios[0].value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                let options: Vec<FormOption> = radios.iter().map(|r| {
                    let value = r.value().attr("value").unwrap_or("").to_string();
                    let id = r.value().attr("id").unwrap_or("");
                    let label = find_label_for(&form, id);
                    let selected = r.value().attr("checked").is_some();
                    FormOption { value, label, selected }
                }).collect();
                fields.push(FormField {
                    name,
                    label: dt_label.clone(),
                    field_type: FormFieldType::Radio { options },
                });
                continue;
            }
        }

        // 4. Checkbox group (multiple checkboxes with same name[])
        let cb_sel = sel("input[type='checkbox'][name^='work_search']");
        let cbs: Vec<ElementRef> = dd.select(&cb_sel).collect();
        if !cbs.is_empty() {
            let name = cbs[0].value().attr("name").unwrap_or("").to_string();
            if !name.is_empty() && seen_names.insert(name.clone()) {
                if cbs.len() == 1 && !name.contains("[]") {
                    // Single checkbox (e.g. single_chapter) — treat as select with on/off
                    let id = cbs[0].value().attr("id").unwrap_or("");
                    let label = if dt_label.is_empty() { find_label_for(&form, id) } else { dt_label.clone() };
                    fields.push(FormField {
                        name,
                        label,
                        field_type: FormFieldType::Checkboxes { options: vec![
                            FormOption { value: "1".to_string(), label: "Yes".to_string(), selected: false },
                        ]},
                    });
                } else {
                    // Multi-checkbox group
                    let options: Vec<FormOption> = cbs.iter().map(|cb| {
                        let value = cb.value().attr("value").unwrap_or("").to_string();
                        let id = cb.value().attr("id").unwrap_or("");
                        let label = find_label_for(&form, id);
                        let selected = cb.value().attr("checked").is_some();
                        FormOption { value, label, selected }
                    }).collect();
                    let label = if dt_label.is_empty() { group_label_from_name(&name) } else { dt_label.clone() };
                    fields.push(FormField {
                        name,
                        label,
                        field_type: FormFieldType::Checkboxes { options },
                    });
                }
                continue;
            }
        }
    }

    // Also pick up fields from the second fieldset (Work Tags, etc.) which uses
    // a different structure with <label>+<input> directly, not always in <dl>
    let fieldset_input_sel = sel("fieldset input[type='text'][name^='work_search']");
    for input in form.select(&fieldset_input_sel) {
        let name = input.value().attr("name").unwrap_or("").to_string();
        if name.is_empty() || !seen_names.insert(name.clone()) { continue; }
        let id = input.value().attr("id").unwrap_or("");
        let label = find_label_for(&form, id);
        fields.push(FormField {
            name,
            label,
            field_type: FormFieldType::Text { placeholder: String::new() },
        });
    }

    Ok(SearchForm { fields })
}

fn find_label_for(form: &ElementRef, id: &str) -> String {
    if id.is_empty() { return String::new(); }
    let label_sel_str = format!("label[for='{}']", id);
    if let Ok(s) = Selector::parse(&label_sel_str) {
        if let Some(label) = form.select(&s).next() {
            let t = text(&label);
            // Strip trailing help link text (often "?" from AO3 help icons)
            let cleaned = t.trim_end_matches('?').trim();
            return cleaned.to_string();
        }
    }
    String::new()
}

fn group_label_from_name(name: &str) -> String {
    // "work_search[archive_warning_ids][]" -> "Archive Warnings"
    // "work_search[category_ids][]" -> "Categories"
    let inner = name
        .trim_start_matches("work_search[")
        .trim_end_matches("][]")
        .trim_end_matches(']');
    match inner {
        "archive_warning_ids" => "Archive Warnings".to_string(),
        "category_ids" => "Categories".to_string(),
        "rating_ids" => "Rating".to_string(),
        _ => {
            inner
                .replace('_', " ")
                .split_whitespace()
                .map(|w| {
                    let mut c = w.chars();
                    match c.next() {
                        None => String::new(),
                        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        }
    }
}
