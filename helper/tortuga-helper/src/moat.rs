//! Bridge lines from the Tor Project's Moat service (bridges.torproject.org),
//! as Tor Browser's Connection Assist gets them:
//! - `circumvention/settings` answers for the caller's country (it finds it
//!   from the address): bridges from BridgeDB where Tor is blocked, an empty
//!   list where it isn't;
//! - `circumvention/builtin` lists the public built-in bridges (obfs4 and
//!   Snowflake, no WebTunnel).
//!
//! Requests go directly, or through Tor's own SOCKS port when the direct way
//! is blocked and Tor already runs (e.g. on Snowflake).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;

pub const MOAT: &str = "https://bridges.torproject.org/moat/circumvention";
const TIMEOUT: Duration = Duration::from_secs(30);

/// The transports Moat can give lines for and the extension stores.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineKind {
    Obfs4,
    Webtunnel,
}

impl LineKind {
    fn name(self) -> &'static str {
        match self {
            LineKind::Obfs4 => "obfs4",
            LineKind::Webtunnel => "webtunnel",
        }
    }
}

/// How the request leaves: directly, or through Tor's SOCKS port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Direct,
    Tor { socks_port: u16 },
}

/// Lines for one transport, and where they came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fetched {
    pub lines: Vec<String>,
    /// "bridgedb" (handed out for this network) or "builtin" (public defaults).
    pub source: String,
    /// The country Moat saw, when it said.
    pub country: Option<String>,
    /// Whether the answer came through Tor.
    pub via_tor: bool,
}

#[derive(Debug, Deserialize)]
struct SettingsAnswer {
    #[serde(default)]
    settings: Option<Vec<Setting>>,
    country: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Setting {
    bridges: SettingBridges,
}

#[derive(Debug, Deserialize)]
struct SettingBridges {
    #[serde(rename = "type")]
    kind: String,
    source: Option<String>,
    #[serde(default)]
    bridge_strings: Option<Vec<String>>,
}

/// Lines found in a `settings` answer, and their source.
pub type Found = Option<(Vec<String>, String)>;

/// Lines of `kind` in a `settings` answer, with their source (None when there
/// are none), and the country Moat saw.
pub fn lines_from_settings(answer: &str, kind: LineKind) -> anyhow::Result<(Found, Option<String>)> {
    let a: SettingsAnswer = serde_json::from_str(answer)?;
    let found = a.settings.unwrap_or_default().into_iter().find_map(|s| {
        let lines = s.bridges.bridge_strings.unwrap_or_default();
        (s.bridges.kind == kind.name() && !lines.is_empty()).then(|| (dedup(lines), s.bridges.source.unwrap_or_else(|| "bridgedb".into())))
    });
    Ok((found, a.country))
}

/// Lines of `kind` in a `builtin` answer (a map from transport to lines), without repeats.
pub fn lines_from_builtin(answer: &str, kind: LineKind) -> anyhow::Result<Vec<String>> {
    let mut map: std::collections::HashMap<String, Vec<String>> = serde_json::from_str(answer)?;
    Ok(dedup(map.remove(kind.name()).unwrap_or_default()))
}

/// Moat answered, but has no lines of this kind for this network. Asking
/// again another way won't help, unlike a failed request.
#[derive(Debug)]
pub struct NoLines(pub String);

impl std::fmt::Display for NoLines {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NoLines {}

fn dedup(lines: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    lines.into_iter().filter(|l| seen.insert(l.clone())).collect()
}

fn client(route: Route) -> anyhow::Result<reqwest::Client> {
    let mut b = reqwest::Client::builder().timeout(TIMEOUT);
    if let Route::Tor { socks_port } = route {
        // socks5h: the name is resolved by Tor, not locally.
        b = b.proxy(reqwest::Proxy::all(format!("socks5h://127.0.0.1:{socks_port}"))?);
    }
    Ok(b.build()?)
}

async fn post(client: &reqwest::Client, base: &str, path: &str, body: serde_json::Value) -> anyhow::Result<String> {
    let res = client
        .post(format!("{base}/{path}"))
        .header("Content-Type", "application/vnd.api+json")
        .body(body.to_string())
        .send()
        .await?
        .error_for_status()?;
    Ok(res.text().await?)
}

/// Lines for `kind`: what Moat hands out for this network, else the built-in ones.
pub async fn fetch(kind: LineKind, route: Route, base: &str) -> anyhow::Result<Fetched> {
    let client = client(route)?;
    let via_tor = matches!(route, Route::Tor { .. });
    let settings = post(&client, base, "settings", json!({ "transports": [kind.name()] })).await?;
    let (found, country) = lines_from_settings(&settings, kind)?;
    if let Some((lines, source)) = found {
        return Ok(Fetched { lines, source, country, via_tor });
    }
    let builtin = post(&client, base, "builtin", json!({ "transports": [kind.name()] })).await?;
    let lines = lines_from_builtin(&builtin, kind)?;
    if lines.is_empty() {
        return Err(NoLines(format!(
            "bridges.torproject.org has no {} bridges for this network{} — it says none are needed here. Paste lines from bridges.torproject.org instead.",
            kind.name(),
            country.as_deref().map(|c| format!(" ({c})")).unwrap_or_default()
        ))
        .into());
    }
    Ok(Fetched { lines, source: "builtin".into(), country, via_tor })
}

#[cfg(test)]
mod tests {
    use super::*;

    const RU: &str = r#"{"settings":[
        {"bridges":{"type":"snowflake","source":"bridgedb","bridge_strings":["snowflake 192.0.2.3:80 AAAA"]}},
        {"bridges":{"type":"obfs4","source":"bridgedb","bridge_strings":["obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0","obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0"]}}
    ],"country":"ru"}"#;

    #[test]
    fn settings_for_a_blocked_country() {
        let (found, country) = lines_from_settings(RU, LineKind::Obfs4).unwrap();
        assert_eq!(found, Some((vec!["obfs4 192.0.2.1:443 BBBB cert=x iat-mode=0".to_string()], "bridgedb".to_string())));
        assert_eq!(country.as_deref(), Some("ru"));
        assert_eq!(lines_from_settings(RU, LineKind::Webtunnel).unwrap().0, None);
    }

    #[test]
    fn settings_where_nothing_is_needed() {
        let (found, country) = lines_from_settings(r#"{"settings":[],"country":"it"}"#, LineKind::Obfs4).unwrap();
        assert_eq!(found, None);
        assert_eq!(country.as_deref(), Some("it"));
        assert_eq!(lines_from_settings(r#"{"settings":null}"#, LineKind::Obfs4).unwrap(), (None, None));
    }

    #[test]
    fn builtin_without_repeats() {
        let answer = r#"{"obfs4":["obfs4 a","obfs4 b","obfs4 a"],"snowflake":["snowflake c"]}"#;
        assert_eq!(lines_from_builtin(answer, LineKind::Obfs4).unwrap(), vec!["obfs4 a", "obfs4 b"]);
        assert!(lines_from_builtin(answer, LineKind::Webtunnel).unwrap().is_empty());
    }

    #[test]
    fn bad_answers_are_errors() {
        assert!(lines_from_settings("<html>", LineKind::Obfs4).is_err());
        assert!(lines_from_builtin("[]", LineKind::Obfs4).is_err());
    }

    #[tokio::test]
    async fn unreachable_service_is_an_error_but_not_no_lines() {
        // Port 1 on localhost: refused at once, no network involved.
        let e = fetch(LineKind::Obfs4, Route::Direct, "http://127.0.0.1:1/moat").await.unwrap_err();
        assert!(e.downcast_ref::<NoLines>().is_none());
    }
}
