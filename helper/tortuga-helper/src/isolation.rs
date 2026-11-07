//! One Arti isolation token per site, so each site gets its own circuits.

use std::collections::HashMap;

use arti_client::IsolationToken;

/// The site used when the browser sends no SOCKS username (Chrome).
pub const DEFAULT_SITE: &str = "default";

/// Sites remembered at most; past that one is forgotten (its next streams
/// just get new circuits), so a long session doesn't grow without end.
pub const MAX_SITES: usize = 1000;

#[derive(Default)]
pub struct IsolationMap {
    tokens: HashMap<String, IsolationToken>,
}

impl IsolationMap {
    /// The token for `site`, created on first use.
    pub fn token_for(&mut self, site: &str) -> IsolationToken {
        if !self.tokens.contains_key(site) && self.tokens.len() >= MAX_SITES {
            let some = self.tokens.keys().next().cloned();
            if let Some(k) = some {
                self.tokens.remove(&k);
            }
        }
        *self.tokens.entry(site.to_owned()).or_insert_with(IsolationToken::new)
    }

    /// Forget every site: each one's next streams use new circuits.
    pub fn clear(&mut self) {
        self.tokens.clear();
    }

    /// Give `site` a fresh token: its next streams use new circuits.
    pub fn renew(&mut self, site: &str) {
        self.tokens.insert(site.to_owned(), IsolationToken::new());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_site_same_token() {
        let mut m = IsolationMap::default();
        assert_eq!(m.token_for("github.com"), m.token_for("github.com"));
    }

    #[test]
    fn different_sites_different_tokens() {
        let mut m = IsolationMap::default();
        assert_ne!(m.token_for("github.com"), m.token_for("wikipedia.org"));
    }

    #[test]
    fn stays_bounded() {
        let mut m = IsolationMap::default();
        for i in 0..MAX_SITES + 10 {
            m.token_for(&format!("site{i}.example"));
        }
        assert_eq!(m.tokens.len(), MAX_SITES);
        let kept = m.token_for("site0.example");
        m.clear();
        assert_ne!(m.token_for("site0.example"), kept);
    }

    #[test]
    fn renew_changes_only_that_site() {
        let mut m = IsolationMap::default();
        let github = m.token_for("github.com");
        let wiki = m.token_for("wikipedia.org");
        m.renew("github.com");
        assert_ne!(m.token_for("github.com"), github);
        assert_eq!(m.token_for("wikipedia.org"), wiki);
    }
}
