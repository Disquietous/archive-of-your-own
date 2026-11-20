//! The site's automatic visitor check (Anubis): a proof of work with no
//! user input. A request without the pass cookie gets a 401 page that
//! carries a challenge as JSON in `script#anubis_challenge`; the visitor
//! finds a number whose SHA-256 with the challenge's random data starts
//! with `difficulty` zero hex digits and hands it to the check's
//! pass-challenge address, which sets the pass cookie and sends the
//! visitor on. The site's own page script does exactly this in the
//! browser; this is that work, done here (design/hentaifoundry-adapter-plan.md).

use scraper::{Html, Selector};
use sha2::{Digest, Sha256};

/// The hardest challenge worked here: 16^6 ≈ 17M hashes on average, a few
/// seconds. The site asks 4 (65k hashes, milliseconds).
pub const MAX_DIFFICULTY: u32 = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Challenge {
    pub id: String,
    pub random_data: String,
    pub difficulty: u32,
    pub algorithm: String,
}

/// A solved challenge: the hash and the number that produced it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub hash: String,
    pub nonce: u64,
}

/// The challenge a check page carries; None when the page is not one.
pub fn parse_challenge(html: &str) -> Option<Challenge> {
    if !html.contains("anubis_challenge") { return None }
    let doc = Html::parse_document(html);
    let script = doc.select(&Selector::parse("script#anubis_challenge").ok()?).next()?;
    let json: serde_json::Value = serde_json::from_str(script.text().collect::<String>().trim()).ok()?;
    let challenge = json.get("challenge")?;
    let rules = json.get("rules")?;
    Some(Challenge {
        id: challenge.get("id")?.as_str()?.to_string(),
        random_data: challenge.get("randomData")?.as_str()?.to_string(),
        difficulty: rules.get("difficulty")?.as_u64()? as u32,
        algorithm: rules.get("algorithm").and_then(|a| a.as_str()).unwrap_or("").to_string(),
    })
}

/// Whether the challenge is the hash work this module does. The check has
/// other kinds (ones only a browser can pass); those are refused by name.
pub fn supported(challenge: &Challenge) -> bool {
    matches!(challenge.algorithm.as_str(), "fast" | "slow") && challenge.difficulty <= MAX_DIFFICULTY
}

fn leading_zero_digits(hash: &[u8], digits: u32) -> bool {
    let whole = (digits / 2) as usize;
    if hash.len() <= whole { return false }
    if hash[..whole].iter().any(|b| *b != 0) { return false }
    digits % 2 == 0 || hash[whole] >> 4 == 0
}

/// Do the work: the first number from 0 whose hash qualifies. CPU-bound;
/// callers run it off the async runtime.
pub fn solve(challenge: &Challenge) -> Answer {
    let mut nonce: u64 = 0;
    loop {
        let mut hasher = Sha256::new();
        hasher.update(challenge.random_data.as_bytes());
        hasher.update(nonce.to_string().as_bytes());
        let hash = hasher.finalize();
        if leading_zero_digits(&hash, challenge.difficulty) {
            return Answer { hash: hash.iter().map(|b| format!("{b:02x}")).collect(), nonce };
        }
        nonce += 1;
    }
}

fn encode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

/// Where the answer is handed in; the check then sends the visitor on to
/// `redir`.
pub fn pass_url(base: &str, challenge: &Challenge, answer: &Answer, redir: &str, elapsed_ms: u64) -> String {
    format!("{base}/.within.website/x/cmd/anubis/api/pass-challenge?id={}&response={}&nonce={}&redir={}&elapsedTime={}",
            encode(&challenge.id), answer.hash, answer.nonce, encode(redir), elapsed_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = include_str!("../../../tests/fixtures/hentaifoundry_check.html");

    #[test]
    fn reads_the_challenge_from_the_check_page() {
        let c = parse_challenge(PAGE).unwrap();
        assert_eq!(c.id, "00000000-1111-7222-8333-444444444444");
        assert_eq!(c.difficulty, 3);
        assert_eq!(c.algorithm, "fast");
        assert!(c.random_data.starts_with("5eed"));
        assert!(supported(&c));
        assert!(parse_challenge("<html><body>A story</body></html>").is_none());
    }

    #[test]
    fn the_answer_hashes_to_the_asked_zeros() {
        let c = parse_challenge(PAGE).unwrap();
        let a = solve(&c);
        assert!(a.hash.starts_with("000"));
        let mut h = Sha256::new();
        h.update(format!("{}{}", c.random_data, a.nonce).as_bytes());
        let again: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(again, a.hash, "the hash is of the data followed by the number");
        // The first qualifying number, as the page's own loop finds it.
        for n in 0..a.nonce {
            let mut h = Sha256::new();
            h.update(format!("{}{n}", c.random_data).as_bytes());
            assert!(!leading_zero_digits(&h.finalize(), 3));
        }
    }

    #[test]
    fn odd_and_even_difficulties_count_hex_digits() {
        assert!(leading_zero_digits(&[0x00, 0x0f, 0xff], 3));
        assert!(!leading_zero_digits(&[0x00, 0x1f, 0xff], 3));
        assert!(leading_zero_digits(&[0x00, 0x00, 0xff], 4));
        assert!(!leading_zero_digits(&[0x00, 0x01, 0xff], 4));
        assert!(leading_zero_digits(&[0xff], 0));
    }

    #[test]
    fn other_kinds_of_check_are_not_attempted() {
        let mut c = parse_challenge(PAGE).unwrap();
        c.algorithm = "metarefresh".to_string();
        assert!(!supported(&c));
        c.algorithm = "fast".to_string();
        c.difficulty = MAX_DIFFICULTY + 1;
        assert!(!supported(&c));
    }

    #[test]
    fn hands_the_answer_in_at_the_checks_address() {
        let c = parse_challenge(PAGE).unwrap();
        let a = Answer { hash: "000abc".to_string(), nonce: 42 };
        assert_eq!(pass_url("https://site.example", &c, &a, "https://site.example/a b?x=1", 350),
                   "https://site.example/.within.website/x/cmd/anubis/api/pass-challenge\
?id=00000000-1111-7222-8333-444444444444&response=000abc&nonce=42\
&redir=https%3A%2F%2Fsite.example%2Fa+b%3Fx%3D1&elapsedTime=350");
    }
}
