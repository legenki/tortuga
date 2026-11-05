//! The Tor side: one Arti client per helper process, its bootstrap progress,
//! and SOCKS connections through it, isolated per site.

use std::io;
use std::sync::{Arc, Mutex};

use arti_client::config::Reconfigure;
use arti_client::status::BootstrapStatus;
use arti_client::{DataStream, DormantMode, StreamPrefs, TorClient, TorClientConfig};
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
    bridge: Mutex<BridgeKind>,
    geoip: Arc<GeoipDb>,
    isolation: Mutex<IsolationMap>,
    tracker: Mutex<CircuitTracker>,
    events: Events,
}

impl Tor {
    /// Create the client and bootstrap it, sending `tor.status` events.
    pub async fn start(config: TorClientConfig, bridge: BridgeKind, events: Events) -> anyhow::Result<Arc<Self>> {
        let client = TorClient::builder().config(config).create_unbootstrapped()?;
        let tor = Arc::new(Self {
            client,
            bridge: Mutex::new(bridge),
            geoip: GeoipDb::new_embedded(),
            isolation: Mutex::default(),
            tracker: Mutex::default(),
            events,
        });
        tor.bootstrap().await?;
        Ok(tor)
    }

    /// Switch an existing client to a new bridge choice and wake it up.
    pub async fn restart(&self, config: &TorClientConfig, bridge: BridgeKind) -> anyhow::Result<()> {
        self.client.reconfigure(config, Reconfigure::AllOrNothing)?;
        *self.bridge.lock().unwrap() = bridge;
        self.client.set_dormant(DormantMode::Normal);
        self.bootstrap().await
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
        let via_bridge = *self.bridge.lock().unwrap() != BridgeKind::None;
        let roles = roles_for(path.n_hops(), via_bridge);
        Some(
            path.iter()
                .zip(roles)
                .filter_map(|(hop, role)| {
                    let target = hop.as_chan_target()?;
                    let ip = target.addrs().next().map(|a| a.ip());
                    let country = ip
                        .and_then(|ip| self.geoip.lookup_country_code(ip))
                        .map(|c| c.get().to_string());
                    let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                    Some(Hop { role, id, addr: ip.map(|ip| ip.to_string()), country })
                })
                .collect(),
        )
    }
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
            if let Some(hops) = tor.hops_of(&stream) {
                if tor.tracker.lock().unwrap().observe(&req.site, &hops) {
                    let bridge = *tor.bridge.lock().unwrap();
                    let bridge = (bridge != BridgeKind::None).then_some(bridge);
                    let _ = tor.events.send(Message::event(Outgoing::Circuit { site: req.site.clone(), bridge, hops }));
                }
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
}
