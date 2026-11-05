//! One Arti isolation token per site, so each site gets its own circuits.

use std::collections::HashMap;

use arti_client::IsolationToken;

/// The site used when the browser sends no SOCKS username (Chrome).
pub const DEFAULT_SITE: &str = "default";

#[derive(Default)]
pub struct IsolationMap {
    tokens: HashMap<String, IsolationToken>,
}

impl IsolationMap {
    /// The token for `site`, created on first use.
    pub fn token_for(&mut self, site: &str) -> IsolationToken {
        *self.tokens.entry(site.to_owned()).or_insert_with(IsolationToken::new)
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
    fn renew_changes_only_that_site() {
        let mut m = IsolationMap::default();
        let github = m.token_for("github.com");
        let wiki = m.token_for("wikipedia.org");
        m.renew("github.com");
        assert_ne!(m.token_for("github.com"), github);
        assert_eq!(m.token_for("wikipedia.org"), wiki);
    }
}
