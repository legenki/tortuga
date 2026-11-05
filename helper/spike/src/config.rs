use arti_client::config::pt::TransportConfigBuilder;
use arti_client::config::{BridgeConfigBuilder, CfgPath, TorClientConfig};

/// Bridges for the spike: bridge lines, plus the transport binary and the
/// protocols it serves (e.g. `["snowflake"]`).
pub struct BridgeSetup {
    pub lines: Vec<String>,
    pub pt_binary: String,
    pub protocols: Vec<String>,
}

/// Default config, or one that bootstraps only through the given bridges.
pub fn tor_config(bridges: Option<&BridgeSetup>) -> anyhow::Result<TorClientConfig> {
    let mut builder = TorClientConfig::builder();
    if let Some(b) = bridges {
        for line in &b.lines {
            let bridge: BridgeConfigBuilder = line.parse()?;
            builder.bridges().bridges().push(bridge);
        }
        let mut transport = TransportConfigBuilder::default();
        let protocols = b.protocols.iter().map(|p| p.parse()).collect::<Result<Vec<_>, _>>()?;
        transport.protocols(protocols).path(CfgPath::new(b.pt_binary.clone())).run_on_startup(true);
        builder.bridges().transports().push(transport);
    }
    Ok(builder.build()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made-up obfs4 line from arti-client's own documentation.
    const FAKE_OBFS4: &str = "Bridge obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbCBvZiBsaXR0bGUgbWVzc2FnZXMgeW91IGNhbiBmaW5kLg iat-mode=0";

    #[test]
    fn default_config_builds() {
        assert!(tor_config(None).is_ok());
    }

    #[test]
    fn bridge_config_builds() {
        let setup = BridgeSetup {
            lines: vec![FAKE_OBFS4.into()],
            pt_binary: "/usr/local/bin/lyrebird".into(),
            protocols: vec!["obfs4".into()],
        };
        assert!(tor_config(Some(&setup)).is_ok());
    }

    #[test]
    fn bad_bridge_line_is_an_error() {
        let setup = BridgeSetup {
            lines: vec!["Bridge not-a-bridge".into()],
            pt_binary: "/usr/local/bin/lyrebird".into(),
            protocols: vec!["obfs4".into()],
        };
        assert!(tor_config(Some(&setup)).is_err());
    }
}
