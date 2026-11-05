//! Circuit hops as the popup shows them, and change detection per site.

use std::collections::HashMap;

use serde::Serialize;

/// What a hop does in a circuit, as the popup's metro diagram names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Guard,
    Bridge,
    Middle,
    Exit,
}

/// One hop: its role, the relay's Ed25519 identity, its address and its
/// country when known (a Snowflake bridge has a placeholder address and no
/// country).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Hop {
    pub role: Role,
    pub id: String,
    pub addr: Option<String>,
    pub country: Option<String>,
}

/// Roles of a circuit's hops in order. The first hop is the bridge when
/// bridges are in use, the guard otherwise; the last is the exit.
pub fn roles_for(n_hops: usize, via_bridge: bool) -> Vec<Role> {
    (0..n_hops)
        .map(|i| match i {
            0 if via_bridge => Role::Bridge,
            0 => Role::Guard,
            i if i + 1 == n_hops => Role::Exit,
            _ => Role::Middle,
        })
        .collect()
}

/// Remembers the last path sent for each site, so a `circuit` event goes out
/// only when a site's path changes.
#[derive(Default)]
pub struct CircuitTracker {
    last: HashMap<String, Vec<Hop>>,
}

impl CircuitTracker {
    /// Record `hops` for `site`; true if they differ from the last ones.
    pub fn observe(&mut self, site: &str, hops: &[Hop]) -> bool {
        if self.last.get(site).is_some_and(|prev| prev == hops) {
            return false;
        }
        self.last.insert(site.to_owned(), hops.to_vec());
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hop(role: Role, id: &str) -> Hop {
        Hop { role, id: id.into(), addr: Some("192.0.2.1".into()), country: Some("DE".into()) }
    }

    #[test]
    fn three_hops_without_bridge() {
        assert_eq!(roles_for(3, false), vec![Role::Guard, Role::Middle, Role::Exit]);
    }

    #[test]
    fn three_hops_through_bridge() {
        assert_eq!(roles_for(3, true), vec![Role::Bridge, Role::Middle, Role::Exit]);
    }

    #[test]
    fn four_hops_have_two_middles() {
        assert_eq!(roles_for(4, false), vec![Role::Guard, Role::Middle, Role::Middle, Role::Exit]);
    }

    #[test]
    fn tracker_reports_only_changes() {
        let mut t = CircuitTracker::default();
        let a = vec![hop(Role::Guard, "g"), hop(Role::Middle, "m"), hop(Role::Exit, "e1")];
        let b = vec![hop(Role::Guard, "g"), hop(Role::Middle, "m"), hop(Role::Exit, "e2")];
        assert!(t.observe("github.com", &a));
        assert!(!t.observe("github.com", &a));
        assert!(t.observe("wikipedia.org", &a));
        assert!(t.observe("github.com", &b));
    }
}
