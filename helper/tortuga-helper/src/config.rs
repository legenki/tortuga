//! Where the helper keeps its files, and the Arti config for a bridge choice.

use std::path::PathBuf;

use arti_client::config::pt::TransportConfigBuilder;
use arti_client::config::{BridgeConfigBuilder, CfgPath, TorClientConfig, TorClientConfigBuilder};

use crate::protocol::{BridgeChoice, BridgeKind};

/// The helper's own directories and the bundled transport.
#[derive(Debug, Clone)]
pub struct Paths {
    pub state_dir: PathBuf,
    pub cache_dir: PathBuf,
    /// `lyrebird`, serving obfs4, WebTunnel, meek and Snowflake.
    pub lyrebird: PathBuf,
    /// The Expert Bundle's `pt_config.json`, for the default Snowflake bridges.
    pub pt_config: PathBuf,
}

impl Paths {
    /// Data under `TORTUGA_DATA_DIR` if set (tests, cold-start runs), else the
    /// platform's data and cache dirs. Transports under `TORTUGA_PT_DIR` if
    /// set, else `pt/` next to the executable.
    pub fn discover() -> anyhow::Result<Self> {
        let (state_dir, cache_dir) = match std::env::var_os("TORTUGA_DATA_DIR") {
            Some(d) => {
                let d = PathBuf::from(d);
                (d.join("state"), d.join("cache"))
            }
            None => {
                let dirs = directories::ProjectDirs::from("org", "Tortuga", "tortuga-helper")
                    .ok_or_else(|| anyhow::anyhow!("no home directory"))?;
                (dirs.data_dir().join("arti-state"), dirs.cache_dir().join("arti-cache"))
            }
        };
        let pt_dir = match std::env::var_os("TORTUGA_PT_DIR") {
            Some(d) => PathBuf::from(d),
            None => std::env::current_exe()?
                .parent()
                .ok_or_else(|| anyhow::anyhow!("executable has no directory"))?
                .join("pt"),
        };
        let exe = if cfg!(windows) { "lyrebird.exe" } else { "lyrebird" };
        Ok(Self { state_dir, cache_dir, lyrebird: pt_dir.join(exe), pt_config: pt_dir.join("pt_config.json") })
    }
}

/// The default Snowflake bridge lines from the Expert Bundle's `pt_config.json`.
pub fn default_snowflake_lines(pt_config_json: &str) -> anyhow::Result<Vec<String>> {
    let v: serde_json::Value = serde_json::from_str(pt_config_json)?;
    let lines = v["bridges"]["snowflake"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("pt_config.json has no snowflake bridges"))?
        .iter()
        .filter_map(|l| l.as_str())
        .map(|l| format!("Bridge {l}"))
        .collect::<Vec<_>>();
    anyhow::ensure!(!lines.is_empty(), "pt_config.json has no snowflake bridges");
    Ok(lines)
}

/// The Arti config for `choice`: own directories, and for bridge kinds only
/// those bridges, through `lyrebird`.
pub fn tor_config(choice: &BridgeChoice, paths: &Paths, default_snowflake: &[String]) -> anyhow::Result<TorClientConfig> {
    let mut builder = TorClientConfigBuilder::from_directories(&paths.state_dir, &paths.cache_dir);
    let (protocol, lines): (&str, Vec<String>) = match choice.kind {
        BridgeKind::None => return Ok(builder.build()?),
        BridgeKind::Snowflake if choice.lines.is_empty() => ("snowflake", default_snowflake.to_vec()),
        BridgeKind::Snowflake => ("snowflake", choice.lines.clone()),
        BridgeKind::Obfs4 => ("obfs4", choice.lines.clone()),
        BridgeKind::Webtunnel => ("webtunnel", choice.lines.clone()),
    };
    anyhow::ensure!(!lines.is_empty(), "{protocol} needs at least one bridge line");
    for line in &lines {
        let bridge: BridgeConfigBuilder = line.parse()?;
        builder.bridges().bridges().push(bridge);
    }
    let mut transport = TransportConfigBuilder::default();
    transport
        .protocols(vec![protocol.parse()?])
        .path(CfgPath::new_literal(&paths.lyrebird))
        .run_on_startup(true);
    builder.bridges().transports().push(transport);
    Ok(builder.build()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made-up obfs4 line from arti-client's own documentation.
    const FAKE_OBFS4: &str = "Bridge obfs4 192.0.2.55:38114 316E643333645F6D79216558614D3931657A5F5F cert=YXJlIGZyZXF1ZW50bHkgZnVsbCBvZiBsaXR0bGUgbWVzc2FnZXMgeW91IGNhbiBmaW5kLg iat-mode=0";
    const FAKE_SNOWFLAKE: &str = "Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72";

    fn paths() -> Paths {
        Paths {
            state_dir: "/tmp/tortuga-test/state".into(),
            cache_dir: "/tmp/tortuga-test/cache".into(),
            lyrebird: "/tmp/tortuga-test/pt/lyrebird".into(),
            pt_config: "/tmp/tortuga-test/pt/pt_config.json".into(),
        }
    }

    fn choice(kind: BridgeKind, lines: &[&str]) -> BridgeChoice {
        BridgeChoice { kind, lines: lines.iter().map(|s| s.to_string()).collect() }
    }

    #[test]
    fn no_bridge_builds() {
        assert!(tor_config(&choice(BridgeKind::None, &[]), &paths(), &[]).is_ok());
    }

    #[test]
    fn snowflake_falls_back_to_defaults() {
        let defaults = vec![FAKE_SNOWFLAKE.to_string()];
        assert!(tor_config(&choice(BridgeKind::Snowflake, &[]), &paths(), &defaults).is_ok());
        assert!(tor_config(&choice(BridgeKind::Snowflake, &[]), &paths(), &[]).is_err());
    }

    #[test]
    fn obfs4_needs_lines() {
        assert!(tor_config(&choice(BridgeKind::Obfs4, &[FAKE_OBFS4]), &paths(), &[]).is_ok());
        assert!(tor_config(&choice(BridgeKind::Obfs4, &[]), &paths(), &[]).is_err());
    }

    #[test]
    fn bad_line_is_an_error() {
        assert!(tor_config(&choice(BridgeKind::Obfs4, &["Bridge nonsense"]), &paths(), &[]).is_err());
    }

    #[test]
    fn reads_default_snowflake_lines() {
        let json = r#"{"bridges": {"snowflake": ["snowflake 192.0.2.3:80 AAAA", "snowflake 192.0.2.4:80 BBBB"]}}"#;
        assert_eq!(
            default_snowflake_lines(json).unwrap(),
            vec!["Bridge snowflake 192.0.2.3:80 AAAA", "Bridge snowflake 192.0.2.4:80 BBBB"]
        );
        assert!(default_snowflake_lines(r#"{"bridges": {}}"#).is_err());
    }
}
