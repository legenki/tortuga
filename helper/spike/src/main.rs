mod config;
mod hops;

use arti_client::{IsolationToken, StreamPrefs, TorClient};
use tor_geoip::GeoipDb;
use tor_linkspec::{HasAddrs, HasRelayIds};
use tor_proto::client::stream::ClientStreamCtrl;

use config::{BridgeSetup, tor_config};
use hops::roles_for;

/// Usage: arti-probe [BRIDGE_LINES_FILE PT_BINARY PROTOCOL]
fn bridge_setup_from_args() -> anyhow::Result<Option<BridgeSetup>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [] => Ok(None),
        [file, pt, protocol] => {
            let lines = std::fs::read_to_string(file)?
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .map(String::from)
                .collect();
            Ok(Some(BridgeSetup { lines, pt_binary: pt.clone(), protocols: vec![protocol.clone()] }))
        }
        _ => anyhow::bail!("usage: arti-probe [BRIDGE_LINES_FILE PT_BINARY PROTOCOL]"),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let bridges = bridge_setup_from_args()?;
    let via_bridge = bridges.is_some();
    let started = std::time::Instant::now();
    let tor = TorClient::create_bootstrapped(tor_config(bridges.as_ref())?).await?;
    println!("bootstrapped in {:.1?}", started.elapsed());
    let geoip = GeoipDb::new_embedded();

    // Two sites with their own tokens, then the first site again with its token:
    // expect two different circuits, and the third line equal to the first.
    let token_a = IsolationToken::new();
    let token_b = IsolationToken::new();
    for (site, token) in [("example.com", token_a), ("example.org", token_b), ("example.com", token_a)] {
        let mut prefs = StreamPrefs::new();
        prefs.set_isolation(token);
        let stream = tor.connect_with_prefs((site, 80), &prefs).await?;
        let ctrl = stream.client_stream_ctrl().ok_or_else(|| anyhow::anyhow!("not a client stream"))?;
        let tunnel = ctrl.tunnel().ok_or_else(|| anyhow::anyhow!("tunnel already closed"))?;
        println!("{site} via tunnel {}", tunnel.unique_id());
        for path in tunnel.all_paths() {
            let roles = roles_for(path.n_hops(), via_bridge);
            for (hop, role) in path.iter().zip(roles) {
                let Some(target) = hop.as_chan_target() else {
                    println!("  {role:?}: virtual hop");
                    continue;
                };
                let addr = target.addrs().next();
                let country = addr
                    .and_then(|a| geoip.lookup_country_code(a.ip()))
                    .map(|c| c.get().to_string())
                    .unwrap_or_else(|| "??".into());
                let id = target.ed_identity().map(|e| e.to_string()).unwrap_or_default();
                println!("  {role:?}: {country} {addr:?} {id}");
            }
        }
    }
    Ok(())
}
