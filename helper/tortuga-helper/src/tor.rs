//! The Tor side: one Arti client per helper process, its bootstrap progress,
//! and SOCKS connections through it, isolated per site.

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use arti_client::config::Reconfigure;
use arti_client::status::BootstrapStatus;
use arti_client::{DataStream, DormantMode, IsolationToken, StreamPrefs, TorClient, TorClientConfig};
use futures::StreamExt;
use tokio::sync::mpsc::UnboundedSender;
use tor_geoip::GeoipDb;
use tor_linkspec::{HasAddrs, HasRelayIds};
use tor_proto::client::stream::ClientStreamCtrl;
use tor_rtcompat::PreferredRuntime;

use crate::hops::{CircuitTracker, Hop, roles_for};
use crate::isolation::IsolationMap;
use crate::protocol::{BridgeKind, Message, Outgoing, Phase};
use crate::socks::{Connector, SocksRequest};

pub type Events = UnboundedSender<Message>;

/// Where a bridge change is proven: any open stream will do; this one is the
/// Tor Project's own page.
const PROBE: (&str, u16) = ("check.torproject.org", 443);
/// How long new bridges get before the change is given up.
const PROVE_WITHIN: Duration = Duration::from_secs(300);
const PROBE_ATTEMPT: Duration = Duration::from_secs(60);

/// The addresses in bridge lines (`[Bridge] transport addr:port fingerprint …`).
pub fn bridge_addrs(lines: &[String]) -> Vec<IpAddr> {
    lines
        .iter()
        .filter_map(|l| {
            let mut words = l.split_whitespace();
            let first = words.next()?;
            let transport_or_addr = if first.eq_ignore_ascii_case("bridge") { words.next()? } else { first };
            let addr = transport_or_addr.parse::<SocketAddr>().ok().or_else(|| words.next()?.parse::<SocketAddr>().ok())?;
            Some(addr.ip())
        })
        .collect()
}

/// Does a circuit whose first hop is `first` show the change has taken? To
/// bridges: it runs through one of the new ones. To no bridge: it doesn't run
/// through one of the old ones.
pub fn proves_switch(first: IpAddr, new: &[IpAddr], old: &[IpAddr]) -> bool {
    if new.is_empty() { !old.contains(&first) } else { new.contains(&first) }
}

/// Bridges a client was proven to run through.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proven {
    pub kind: BridgeKind,
    /// Their addresses (empty without bridges).
    pub addrs: Vec<IpAddr>,
}

/// What a client is known to run through. A switch reconfigures the client
/// before it is proven, so from then until it succeeds nothing is settled,
/// and every bridge configured meanwhile (a switch that failed or was
/// cancelled half way) may still carry circuits. The next switch, even back
/// to the bridges proven before, is proven away from all of them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Switches {
    /// The bridges last proven, while settled.
    proven: Option<Proven>,
    /// Bridge addresses configured since then.
    tried: Vec<IpAddr>,
}

impl Switches {
    pub fn settled(kind: BridgeKind, addrs: Vec<IpAddr>) -> Self {
        Self { proven: Some(Proven { kind, addrs }), tried: Vec::new() }
    }

    /// Begin a switch to `new` (call before reconfiguring): the addresses to
    /// prove it away from, or None when the client already runs, proven, on
    /// exactly these. Unsettled until `settle`.
    pub fn begin(&mut self, new: &[IpAddr]) -> Option<Vec<IpAddr>> {
        let last = self.proven.take();
        let needs_proof = last.as_ref().is_none_or(|p| p.addrs != new);
        if let Some(p) = last {
            self.tried.extend(p.addrs);
        }
        let mut old: Vec<IpAddr> = self.tried.iter().copied().filter(|a| !new.contains(a)).collect();
        old.sort();
        old.dedup();
        self.tried.extend_from_slice(new);
        needs_proof.then_some(old)
    }

    /// The switch succeeded: the client runs through these.
    pub fn settle(&mut self, kind: BridgeKind, addrs: Vec<IpAddr>) {
        *self = Self::settled(kind, addrs);
    }

    /// The bridge kind proven, `None` while unsettled (no SOCKS port is open then).
    pub fn kind(&self) -> BridgeKind {
        self.proven.as_ref().map_or(BridgeKind::None, |p| p.kind)
    }
}

/// Arti reports one fraction: 15 % for reaching the first hop, 85 % for the
/// directory. The phases follow that split.
pub fn phase_for(frac: f32, ready: bool) -> Phase {
    if ready {
        Phase::Ready
    } else if frac < 0.15 {
        Phase::Bridge
    } else {
        Phase::Directory
    }
}

fn status_event(s: &BootstrapStatus) -> Outgoing {
    let frac = s.as_frac().clamp(0.0, 1.0);
    Outgoing::TorStatus {
        phase: phase_for(frac, s.ready_for_traffic()),
        percent: (frac * 100.0).round() as u8,
        blocked: s.blocked().map(|b| b.message().to_string()),
    }
}

pub struct Tor {
    client: Arc<TorClient<PreferredRuntime>>,
    /// What the client is known to run through.
    switches: Mutex<Switches>,
    geoip: Arc<GeoipDb>,
    isolation: Mutex<IsolationMap>,
    tracker: Mutex<CircuitTracker>,
    events: Events,
}

impl Tor {
    /// Create the client and bootstrap it, sending `tor.status` events.
    /// `lines` are the bridge lines in `config` (empty without bridges).
    pub async fn start(config: TorClientConfig, bridge: BridgeKind, lines: &[String], events: Events) -> anyhow::Result<Arc<Self>> {
        let client = TorClient::builder().config(config).create_unbootstrapped()?;
        let tor = Arc::new(Self {
            client,
            // Only stored once bootstrap succeeds below.
            switches: Mutex::new(Switches::settled(bridge, bridge_addrs(lines))),
            geoip: GeoipDb::new_embedded(),
            isolation: Mutex::default(),
            tracker: Mutex::default(),
            events,
        });
        tor.bootstrap().await?;
        Ok(tor)
    }

    /// Switch an existing client to a new bridge choice and wake it up. Done
    /// only once a circuit runs the new way: the directory is cached, so Arti
    /// says it's ready at once, before the new bridges have answered.
    ///
    /// Every site then gets fresh circuits: ones kept from before the change
    /// may run through the old bridges or guard.
    ///
    /// What is proven changes only at the end, after success: a switch that
    /// fails or is cancelled (a newer start, a stop) leaves the last proven
    /// bridges, so trying the same new ones again proves them again.
    pub async fn restart(&self, config: &TorClientConfig, bridge: BridgeKind, lines: &[String]) -> anyhow::Result<()> {
        let new = bridge_addrs(lines);
        let prove_against = self.switches.lock().unwrap().begin(&new);
        self.client.reconfigure(config, Reconfigure::AllOrNothing)?;
        self.isolation.lock().unwrap().clear();
        self.tracker.lock().unwrap().clear();
        self.client.set_dormant(DormantMode::Normal);
        if let Some(old) = prove_against {
            // The connecting diagram shows "reaching the first hop" meanwhile.
            let _ = self.events.send(Message::event(Outgoing::TorStatus { phase: Phase::Bridge, percent: 10, blocked: None }));
            self.prove(&new, &old).await?;
        }
        self.bootstrap().await?;
        self.switches.lock().unwrap().settle(bridge, new);
        Ok(())
    }

    /// Open test streams on fresh circuits until one runs the new way.
    async fn prove(&self, new: &[IpAddr], old: &[IpAddr]) -> anyhow::Result<()> {
        let deadline = Instant::now() + PROVE_WITHIN;
        loop {
            let mut prefs = StreamPrefs::new();
            prefs.set_isolation(IsolationToken::new());
            if let Ok(Ok(stream)) = tokio::time::timeout(PROBE_ATTEMPT, self.client.connect_with_prefs(PROBE, &prefs)).await
                && first_hop_ip(&stream).is_some_and(|ip| proves_switch(ip, new, old))
            {
                return Ok(());
            }
            anyhow::ensure!(
                Instant::now() < deadline,
                "the new bridges didn't answer within {} minutes — try another bridge",
                PROVE_WITHIN.as_secs() / 60
            );
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    /// Stop building circuits until the next `restart`.
    pub fn sleep(&self) {
        self.client.set_dormant(DormantMode::Soft);
    }

    pub fn new_circuit(&self, site: &str) {
        self.isolation.lock().unwrap().renew(site);
    }

    async fn bootstrap(&self) -> anyhow::Result<()> {
        let mut statuses = self.client.bootstrap_events();
        let events = self.events.clone();
        let forward = tokio::spawn(async move {
            while let Some(s) = statuses.next().await {
                if events.send(Message::event(status_event(&s))).is_err() || s.ready_for_traffic() {
                    break;
                }
            }
        });
        let result = self.client.bootstrap().await;
        forward.abort();
        result?;
        let _ = self.events.send(Message::event(Outgoing::TorStatus { phase: Phase::Ready, percent: 100, blocked: None }));
        Ok(())
    }

    /// The path of the tunnel `stream` runs on.
    fn hops_of(&self, stream: &DataStream) -> Option<Vec<Hop>> {
        let tunnel = stream.client_stream_ctrl()?.tunnel()?;
        let path = tunnel.all_paths().into_iter().next()?;
        let via_bridge = self.switches.lock().unwrap().kind() != BridgeKind::None;
        // Only hops that are relays: an onion service circuit ends in a
        // virtual hop, which must not take the exit's place in the roles.
        let targets: Vec<_> = path.iter().filter_map(|hop| hop.as_chan_target()).collect();
        let roles = roles_for(targets.len(), via_bridge);
        Some(
            targets
                .into_iter()
                .zip(roles)
                .map(|(target, role)| {
                    let ip = target.addrs().next().map(|a| a.ip());
                    let country = ip
                        .and_then(|ip| self.geoip.lookup_country_code(ip))
                        .map(|c| c.get().to_string());
                    let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                    Hop { role, id, addr: ip.map(|ip| ip.to_string()), country }
                })
                .collect(),
        )
    }
}

/// The address of the first hop of the circuit `stream` runs on.
fn first_hop_ip(stream: &DataStream) -> Option<IpAddr> {
    let tunnel = stream.client_stream_ctrl()?.tunnel()?;
    let path = tunnel.all_paths().into_iter().next()?;
    let first = path.iter().next()?.as_chan_target()?.addrs().next()?;
    Some(first.ip())
}

impl Connector for Arc<Tor> {
    type Stream = DataStream;

    fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<DataStream>> + Send {
        let tor = self.clone();
        async move {
            let token = tor.isolation.lock().unwrap().token_for(&req.site);
            let mut prefs = StreamPrefs::new();
            prefs.set_isolation(token);
            let stream = tor
                .client
                .connect_with_prefs((req.host.as_str(), req.port), &prefs)
                .await
                .map_err(io::Error::other)?;
            if let Some(hops) = tor.hops_of(&stream)
                && tor.tracker.lock().unwrap().observe(&req.site, &hops)
            {
                let bridge = tor.switches.lock().unwrap().kind();
                let bridge = (bridge != BridgeKind::None).then_some(bridge);
                let _ = tor.events.send(Message::event(Outgoing::Circuit { site: req.site.clone(), bridge, hops }));
            }
            Ok(stream)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_follow_arti_fraction() {
        assert_eq!(phase_for(0.0, false), Phase::Bridge);
        assert_eq!(phase_for(0.14, false), Phase::Bridge);
        assert_eq!(phase_for(0.15, false), Phase::Directory);
        assert_eq!(phase_for(0.99, false), Phase::Directory);
        assert_eq!(phase_for(0.5, true), Phase::Ready);
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn bridge_addresses_from_lines() {
        let lines = [
            "Bridge obfs4 212.83.43.95:443 BFE712113A72899AD685764B211FACD30FF52C31 cert=x iat-mode=1".to_string(),
            "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://x".to_string(),
            "Bridge webtunnel [2001:db8::1]:443 8838024498816A039FCBBAB14E6F40A0843051FA url=https://y".to_string(),
            "Bridge nonsense".to_string(),
        ];
        assert_eq!(bridge_addrs(&lines), vec![ip("212.83.43.95"), ip("192.0.2.3"), ip("2001:db8::1")]);
    }

    #[test]
    fn a_switch_to_the_proven_bridges_needs_no_proof() {
        let snowflake = vec![ip("192.0.2.3")];
        let mut s = Switches::settled(BridgeKind::Snowflake, snowflake.clone());
        assert_eq!(s.begin(&snowflake), None);
        s.settle(BridgeKind::Snowflake, snowflake);
        assert_eq!(s.kind(), BridgeKind::Snowflake);
    }

    #[test]
    fn a_failed_or_cancelled_switch_is_proven_again() {
        let snowflake = vec![ip("192.0.2.3")];
        let obfs4 = vec![ip("212.83.43.95")];
        let mut s = Switches::settled(BridgeKind::Snowflake, snowflake.clone());
        assert_eq!(s.begin(&obfs4), Some(snowflake.clone()));
        // It failed or was cancelled: trying obfs4 again is proven again (it
        // used to be skipped, and the cached directory made it "ready"
        // through bridges that never answered).
        assert_eq!(s.begin(&obfs4), Some(snowflake));
        assert_eq!(s.kind(), BridgeKind::None);
    }

    #[test]
    fn going_back_after_a_cancelled_switch_is_proven_away_from_it() {
        // No bridge, then obfs4 cancelled after the client was reconfigured,
        // then no bridge again: the client may hold circuits through obfs4,
        // so the way back is proven not to run through it.
        let obfs4 = vec![ip("212.83.43.95")];
        let mut s = Switches::settled(BridgeKind::None, vec![]);
        assert_eq!(s.begin(&obfs4), Some(vec![]));
        assert_eq!(s.begin(&[]), Some(obfs4.clone()));
        s.settle(BridgeKind::None, vec![]);
        // Settled: what was tried is forgotten.
        assert_eq!(s.begin(&[]), None);
    }

    #[test]
    fn a_switch_is_proven_by_its_first_hop() {
        let snowflake = [ip("192.0.2.3"), ip("192.0.2.4")];
        let obfs4 = [ip("212.83.43.95"), ip("45.145.95.6")];
        // To bridges: the first hop must be one of the new bridges.
        assert!(proves_switch(ip("212.83.43.95"), &obfs4, &snowflake));
        assert!(!proves_switch(ip("192.0.2.3"), &obfs4, &snowflake));
        // To no bridge: any guard, as long as it isn't one of the old bridges.
        assert!(proves_switch(ip("64.65.1.161"), &[], &snowflake));
        assert!(!proves_switch(ip("192.0.2.4"), &[], &snowflake));
    }
}
