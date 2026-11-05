/// What a hop does in a circuit, as the popup's metro diagram names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Guard,
    Bridge,
    Middle,
    Exit,
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
