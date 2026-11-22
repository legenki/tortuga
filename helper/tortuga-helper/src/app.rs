//! Handles requests from the extension: hello, then Tor (start, stop, new
//! circuit, resolve) and bridge lines. Long work runs in tasks, so a
//! `tor.stop` can cancel a start and a slow request doesn't hold up others.

use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::config::{Paths, bridge_lines, default_snowflake_lines, tor_config};
use crate::moat::{self, LineKind, Route};
use crate::protocol::{BridgeChoice, ErrorCode, FEATURES, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody};
use crate::tor::{Events, Tor};

/// `TORTUGA_DEBUG` set: log details that can name visited sites.
static DEBUG: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| std::env::var_os("TORTUGA_DEBUG").is_some());

#[derive(Default)]
struct State {
    hello: bool,
    tor: Option<Arc<Tor>>,
    /// The bootstrap in progress, if any, and the id of the request it answers.
    starting: Option<(u64, JoinHandle<()>)>,
    /// The SOCKS listener while Tor is on, and its port.
    socks: Option<JoinHandle<()>>,
    socks_port: Option<u16>,
}

#[derive(Clone)]
pub struct App {
    state: Arc<Mutex<State>>,
    paths: Paths,
    events: Events,
}

impl App {
    pub fn new(paths: Paths, events: Events) -> Self {
        Self { state: Arc::default(), paths, events }
    }

    fn send(&self, m: Message) {
        let _ = self.events.send(m);
    }

    pub async fn handle(&self, req: Request) {
        let mut state = self.state.lock().await;
        if !state.hello && !matches!(req.body, RequestBody::Hello { .. }) {
            return self.send(Message::error(Some(req.id), ErrorCode::HelloRequired, "send hello first"));
        }
        match req.body {
            RequestBody::Hello { protocol } if protocol == PROTOCOL_VERSION => {
                state.hello = true;
                let version = env!("CARGO_PKG_VERSION").to_owned();
                self.send(Message::reply(req.id, Outgoing::Hello { protocol: PROTOCOL_VERSION, version, features: FEATURES.to_vec() }));
            }
            RequestBody::Hello { protocol } => self.send(Message::error(
                Some(req.id),
                ErrorCode::ProtocolMismatch,
                format!("helper speaks protocol {PROTOCOL_VERSION}, extension {protocol}"),
            )),
            RequestBody::TorStart { bridge } => {
                self.stop(&mut state);
                let app = self.clone();
                state.starting = Some((req.id, tokio::spawn(async move { app.start(req.id, bridge).await })));
            }
            RequestBody::TorStop => {
                self.stop(&mut state);
                self.send(Message::reply(req.id, Outgoing::Ok));
            }
            RequestBody::TorNewCircuit { site } => match &state.tor {
                Some(tor) if state.socks.is_some() => {
                    tor.new_circuit(&site);
                    self.send(Message::reply(req.id, Outgoing::Ok));
                }
                _ => self.send(Message::error(Some(req.id), ErrorCode::NotRunning, "Tor is off")),
            },
            RequestBody::TorResolve { name } => match &state.tor {
                Some(tor) if state.socks.is_some() => {
                    let tor = tor.clone();
                    let app = self.clone();
                    tokio::spawn(async move {
                        let reply = match tor.resolve(&name).await {
                            Ok(ips) => Message::reply(req.id, Outgoing::Resolved { addresses: ips.iter().map(|ip| ip.to_string()).collect() }),
                            Err(e) => Message::error(Some(req.id), ErrorCode::TorFailed, format!("{e:#}")),
                        };
                        app.send(reply);
                    });
                }
                _ => self.send(Message::error(Some(req.id), ErrorCode::NotRunning, "Tor is off")),
            },
            RequestBody::BridgesFetch { kind } => {
                let app = self.clone();
                let socks_port = state.socks_port;
                tokio::spawn(async move {
                    let reply = match app.fetch_bridges(kind, socks_port).await {
                        Ok(fetched) => Message::reply(req.id, Outgoing::BridgesLines(fetched)),
                        Err(e) => Message::error(Some(req.id), ErrorCode::BridgesFailed, format!("{e:#}")),
                    };
                    app.send(reply);
                });
            }
        }
    }

    /// Ask Moat directly; if that fails and Tor is on, ask again through Tor.
    /// `TORTUGA_MOAT_URL` replaces the service (tests); `TORTUGA_MOAT_NO_DIRECT`
    /// skips the direct try, to exercise the way through Tor.
    async fn fetch_bridges(&self, kind: LineKind, socks_port: Option<u16>) -> anyhow::Result<moat::Fetched> {
        let base = std::env::var("TORTUGA_MOAT_URL").unwrap_or_else(|_| moat::MOAT.to_owned());
        let direct = if std::env::var_os("TORTUGA_MOAT_NO_DIRECT").is_some() {
            Err(anyhow::anyhow!("direct requests switched off"))
        } else {
            moat::fetch(kind, Route::Direct, &base).await
        };
        match (direct, socks_port) {
            (Ok(fetched), _) => Ok(fetched),
            // Moat answered: it has nothing for this network, and Tor won't change that.
            (Err(e), _) if e.downcast_ref::<moat::NoLines>().is_some() => Err(e),
            (Err(e), Some(port)) => moat::fetch(kind, Route::Tor { socks_port: port }, &base)
                .await
                .map_err(|via_tor| anyhow::anyhow!("bridges.torproject.org: {e:#}; through Tor: {via_tor:#}")),
            (Err(e), None) => Err(anyhow::anyhow!(
                "Can't reach bridges.torproject.org ({e:#}). Turn Tor on with Snowflake, then try again: the request will go through Tor."
            )),
        }
    }

    async fn start(&self, id: u64, bridge: BridgeChoice) {
        match self.try_start(id, &bridge).await {
            Ok(socks_port) => self.send(Message::reply(id, Outgoing::TorReady { socks_port })),
            Err(e) => {
                let mut state = self.state.lock().await;
                // Replaced meanwhile: stop() already answered it, and the
                // state belongs to the newer start.
                if !is_starting(&state, id) {
                    return;
                }
                // Don't leave a client that failed building circuits.
                state.starting = None;
                if let Some(tor) = &state.tor {
                    tor.sleep();
                }
                drop(state);
                self.send(Message::error(Some(id), ErrorCode::TorFailed, format!("{e:#}")));
            }
        }
    }

    /// Cancel a start in progress (answering its request), close the SOCKS
    /// port and let Tor sleep.
    fn stop(&self, state: &mut State) {
        if let Some((id, t)) = state.starting.take() {
            t.abort();
            self.send(Message::error(Some(id), ErrorCode::Cancelled, "replaced by a newer request"));
        }
        if let Some(s) = state.socks.take() {
            s.abort();
        }
        state.socks_port = None;
        if let Some(tor) = &state.tor {
            tor.sleep();
        }
    }

    async fn try_start(&self, id: u64, bridge: &BridgeChoice) -> anyhow::Result<u16> {
        let defaults = match std::fs::read_to_string(&self.paths.pt_config) {
            Ok(json) => default_snowflake_lines(&json)?,
            Err(_) => Vec::new(),
        };
        let config = tor_config(bridge, &self.paths, &defaults)?;
        let lines = bridge_lines(bridge, &defaults);
        let existing = self.state.lock().await.tor.clone();
        let (tor, fresh) = match existing {
            Some(tor) => {
                tor.restart(&config, bridge.kind, &lines).await?;
                (tor, false)
            }
            None => (Tor::start(config, bridge.kind, &lines, self.events.clone()).await?, true),
        };
        // A client this start created is nobody else's until it is stored:
        // cancelled from here on (an abort lands at an await), it goes to
        // sleep instead of building circuits for no one. A client already in
        // the state is stop()'s to put to sleep, and may be a newer start's.
        let guard = SleepUnlessKept(fresh.then(|| tor.clone()));
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let mut state = self.state.lock().await;
        anyhow::ensure!(is_starting(&state, id), "replaced by a newer request");
        // No await from here on: the SOCKS task is stored as soon as it runs.
        let socks = tokio::spawn(serve(listener, tor.clone()));
        guard.keep();
        state.tor = Some(tor);
        state.socks = Some(socks);
        state.socks_port = Some(port);
        state.starting = None;
        Ok(port)
    }
}

/// Is the start in progress the one answering request `id`?
fn is_starting(state: &State, id: u64) -> bool {
    matches!(state.starting, Some((i, _)) if i == id)
}

/// Puts a Tor client to sleep when dropped, unless kept.
struct SleepUnlessKept(Option<Arc<Tor>>);

impl SleepUnlessKept {
    fn keep(mut self) {
        self.0 = None;
    }
}

impl Drop for SleepUnlessKept {
    fn drop(&mut self) {
        if let Some(tor) = self.0.take() {
            tor.sleep();
        }
    }
}

async fn serve(listener: TcpListener, tor: Arc<Tor>) {
    while let Ok((client, _)) = listener.accept().await {
        let tor = tor.clone();
        tokio::spawn(async move {
            // Errors can name the sites being visited: logged only on request.
            if let Err(e) = crate::socks::handle(client, &tor).await
                && *DEBUG
            {
                eprintln!("socks: {e}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use tokio::sync::mpsc::UnboundedReceiver;

    /// The app, its outbox, and its data folder (removed when dropped).
    fn app() -> (App, UnboundedReceiver<Message>, tempfile::TempDir) {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().to_path_buf();
        let paths = Paths {
            state_dir: dir.join("state"),
            cache_dir: dir.join("cache"),
            lyrebird: dir.join("pt/lyrebird"),
            pt_config: dir.join("pt/pt_config.json"),
        };
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (App::new(paths, tx), rx, tmp)
    }

    fn req(v: Value) -> Request {
        serde_json::from_value(v).unwrap()
    }

    fn json_of(m: Message) -> Value {
        serde_json::to_value(m).unwrap()
    }

    #[tokio::test]
    async fn hello_first() {
        let (app, mut rx, _dir) = app();
        app.handle(req(json!({"id": 1, "type": "tor.stop"}))).await;
        assert_eq!(json_of(rx.recv().await.unwrap())["payload"]["code"], "hello_required");
        app.handle(req(json!({"id": 2, "type": "hello", "payload": {"protocol": 99}}))).await;
        assert_eq!(json_of(rx.recv().await.unwrap())["payload"]["code"], "protocol_mismatch");
        app.handle(req(json!({"id": 3, "type": "hello", "payload": {"protocol": PROTOCOL_VERSION}}))).await;
        let hello = json_of(rx.recv().await.unwrap());
        assert_eq!(hello["type"], "hello");
        assert_eq!(hello["payload"]["features"], json!(FEATURES));
        app.handle(req(json!({"id": 4, "type": "tor.stop"}))).await;
        assert_eq!(json_of(rx.recv().await.unwrap()), json!({"id": 4, "type": "ok"}));
    }

    #[tokio::test]
    async fn a_replaced_start_is_answered() {
        let (app, mut rx, _dir) = app();
        app.handle(req(json!({"id": 1, "type": "hello", "payload": {"protocol": PROTOCOL_VERSION}}))).await;
        rx.recv().await.unwrap();
        // Two starts and a stop in a row, before any could finish: every one
        // gets its answer, so the extension never waits forever.
        app.handle(req(json!({"id": 2, "type": "tor.start", "payload": {"bridge": {"kind": "none"}}}))).await;
        app.handle(req(json!({"id": 3, "type": "tor.start", "payload": {"bridge": {"kind": "none"}}}))).await;
        app.handle(req(json!({"id": 4, "type": "tor.stop"}))).await;
        let answers: Vec<Value> = (0..3).map(|_| json_of(rx.try_recv().unwrap())).collect();
        assert_eq!(answers[0], json!({"id": 2, "type": "error", "payload": {"code": "cancelled", "message": "replaced by a newer request"}}));
        assert_eq!(answers[1]["id"], 3);
        assert_eq!(answers[1]["payload"]["code"], "cancelled");
        assert_eq!(answers[2], json!({"id": 4, "type": "ok"}));
    }

    #[tokio::test]
    async fn resolve_needs_tor() {
        let (app, mut rx, _dir) = app();
        app.handle(req(json!({"id": 1, "type": "hello", "payload": {"protocol": PROTOCOL_VERSION}}))).await;
        rx.recv().await.unwrap();
        app.handle(req(json!({"id": 2, "type": "tor.resolve", "payload": {"name": "example.com"}}))).await;
        let answer = json_of(rx.recv().await.unwrap());
        assert_eq!(answer["id"], 2);
        assert_eq!(answer["payload"]["code"], "not_running");
    }

    #[tokio::test]
    async fn new_circuit_needs_tor() {
        let (app, mut rx, _dir) = app();
        app.handle(req(json!({"id": 1, "type": "hello", "payload": {"protocol": PROTOCOL_VERSION}}))).await;
        rx.recv().await.unwrap();
        app.handle(req(json!({"id": 2, "type": "tor.newCircuit", "payload": {"site": "example.org"}}))).await;
        assert_eq!(json_of(rx.recv().await.unwrap())["payload"]["code"], "not_running");
    }
}
