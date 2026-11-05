//! Messages between the extension and the helper (spec: "Protocol").
//! Every message is `{ id?, type, payload? }`; replies carry the request's id.

use serde::{Deserialize, Serialize};

use crate::hops::Hop;

/// Bumped whenever a message changes incompatibly.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize, PartialEq)]
pub struct Request {
    pub id: u64,
    #[serde(flatten)]
    pub body: RequestBody,
}

#[derive(Debug, Deserialize, PartialEq)]
#[serde(tag = "type", content = "payload")]
pub enum RequestBody {
    #[serde(rename = "hello")]
    Hello { protocol: u32 },
    #[serde(rename = "tor.start")]
    TorStart { bridge: BridgeChoice },
    #[serde(rename = "tor.stop")]
    TorStop,
    #[serde(rename = "tor.newCircuit")]
    TorNewCircuit { site: String },
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct BridgeChoice {
    pub kind: BridgeKind,
    #[serde(default)]
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BridgeKind {
    None,
    Snowflake,
    Obfs4,
    Webtunnel,
}

/// Where bootstrap is, for the connecting animation.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    /// Reaching the first hop (bridge or guard).
    Bridge,
    /// Downloading the network directory.
    Directory,
    Ready,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Message {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(flatten)]
    pub body: Outgoing,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "type", content = "payload")]
pub enum Outgoing {
    #[serde(rename = "hello")]
    Hello { protocol: u32, version: String },
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "tor.status")]
    TorStatus { phase: Phase, percent: u8, blocked: Option<String> },
    #[serde(rename = "tor.ready", rename_all = "camelCase")]
    TorReady { socks_port: u16 },
    #[serde(rename = "circuit")]
    Circuit { site: String, bridge: Option<BridgeKind>, hops: Vec<Hop> },
    #[serde(rename = "error")]
    Error { code: ErrorCode, message: String },
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BadRequest,
    HelloRequired,
    ProtocolMismatch,
    TorFailed,
    NotRunning,
}

impl Message {
    pub fn reply(id: u64, body: Outgoing) -> Self {
        Self { id: Some(id), body }
    }

    pub fn event(body: Outgoing) -> Self {
        Self { id: None, body }
    }

    pub fn error(id: Option<u64>, code: ErrorCode, message: impl ToString) -> Self {
        Self { id, body: Outgoing::Error { code, message: message.to_string() } }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hops::Role;
    use serde_json::json;

    fn parse(v: serde_json::Value) -> Request {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn parses_requests() {
        assert_eq!(
            parse(json!({"id": 1, "type": "hello", "payload": {"protocol": 1}})),
            Request { id: 1, body: RequestBody::Hello { protocol: 1 } }
        );
        assert_eq!(
            parse(json!({"id": 2, "type": "tor.start", "payload": {"bridge": {"kind": "snowflake"}}})),
            Request { id: 2, body: RequestBody::TorStart { bridge: BridgeChoice { kind: BridgeKind::Snowflake, lines: vec![] } } }
        );
        assert_eq!(parse(json!({"id": 3, "type": "tor.stop"})), Request { id: 3, body: RequestBody::TorStop });
        assert_eq!(
            parse(json!({"id": 4, "type": "tor.newCircuit", "payload": {"site": "github.com"}})),
            Request { id: 4, body: RequestBody::TorNewCircuit { site: "github.com".into() } }
        );
    }

    #[test]
    fn rejects_unknown_type() {
        assert!(serde_json::from_value::<Request>(json!({"id": 1, "type": "tor.explode"})).is_err());
    }

    #[test]
    fn serializes_replies_and_events() {
        let ok = serde_json::to_value(Message::reply(3, Outgoing::Ok)).unwrap();
        assert_eq!(ok, json!({"id": 3, "type": "ok"}));

        let ready = serde_json::to_value(Message::reply(2, Outgoing::TorReady { socks_port: 9150 })).unwrap();
        assert_eq!(ready, json!({"id": 2, "type": "tor.ready", "payload": {"socksPort": 9150}}));

        let status = serde_json::to_value(Message::event(Outgoing::TorStatus { phase: Phase::Directory, percent: 40, blocked: None })).unwrap();
        assert_eq!(status, json!({"type": "tor.status", "payload": {"phase": "directory", "percent": 40, "blocked": null}}));

        let circuit = serde_json::to_value(Message::event(Outgoing::Circuit {
            site: "github.com".into(),
            bridge: Some(BridgeKind::Snowflake),
            hops: vec![Hop { role: Role::Bridge, id: "abc".into(), addr: Some("192.0.2.3".into()), country: None }],
        }))
        .unwrap();
        assert_eq!(
            circuit,
            json!({"type": "circuit", "payload": {"site": "github.com", "bridge": "snowflake",
                   "hops": [{"role": "bridge", "id": "abc", "addr": "192.0.2.3", "country": null}]}})
        );

        let err = serde_json::to_value(Message::error(Some(5), ErrorCode::ProtocolMismatch, "want 1")).unwrap();
        assert_eq!(err, json!({"id": 5, "type": "error", "payload": {"code": "protocol_mismatch", "message": "want 1"}}));
    }
}
