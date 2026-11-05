//! Handles requests from the extension: hello, then starting, stopping and
//! renewing Tor. Long work runs in tasks so a `tor.stop` can cancel a start.

use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::config::{Paths, default_snowflake_lines, tor_config};
use crate::protocol::{BridgeChoice, ErrorCode, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody};
use crate::tor::{Events, Tor};

#[derive(Default)]
struct State {
    hello: bool,
    tor: Option<Arc<Tor>>,
    /// The bootstrap in progress, if any.
    starting: Option<JoinHandle<()>>,
    /// The SOCKS listener while Tor is on.
    socks: Option<JoinHandle<()>>,
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
                self.send(Message::reply(req.id, Outgoing::Hello { protocol: PROTOCOL_VERSION, version }));
            }
            RequestBody::Hello { protocol } => self.send(Message::error(
                Some(req.id),
                ErrorCode::ProtocolMismatch,
                format!("helper speaks protocol {PROTOCOL_VERSION}, extension {protocol}"),
            )),
            RequestBody::TorStart { bridge } => {
                stop(&mut state);
                let app = self.clone();
                state.starting = Some(tokio::spawn(async move { app.start(req.id, bridge).await }));
            }
            RequestBody::TorStop => {
                stop(&mut state);
                self.send(Message::reply(req.id, Outgoing::Ok));
            }
            RequestBody::TorNewCircuit { site } => match &state.tor {
                Some(tor) if state.socks.is_some() => {
                    tor.new_circuit(&site);
                    self.send(Message::reply(req.id, Outgoing::Ok));
                }
                _ => self.send(Message::error(Some(req.id), ErrorCode::NotRunning, "Tor is off")),
            },
        }
    }

    async fn start(&self, id: u64, bridge: BridgeChoice) {
        match self.try_start(&bridge).await {
            Ok(socks_port) => self.send(Message::reply(id, Outgoing::TorReady { socks_port })),
            Err(e) => self.send(Message::error(Some(id), ErrorCode::TorFailed, format!("{e:#}"))),
        }
    }

    async fn try_start(&self, bridge: &BridgeChoice) -> anyhow::Result<u16> {
        let defaults = match std::fs::read_to_string(&self.paths.pt_config) {
            Ok(json) => default_snowflake_lines(&json)?,
            Err(_) => Vec::new(),
        };
        let config = tor_config(bridge, &self.paths, &defaults)?;
        let existing = self.state.lock().await.tor.clone();
        let tor = match existing {
            Some(tor) => {
                tor.restart(&config, bridge.kind).await?;
                tor
            }
            None => Tor::start(config, bridge.kind, self.events.clone()).await?,
        };
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let socks = tokio::spawn(serve(listener, tor.clone()));
        let mut state = self.state.lock().await;
        state.tor = Some(tor);
        state.socks = Some(socks);
        state.starting = None;
        Ok(port)
    }
}

/// Cancel a start in progress, close the SOCKS port and let Tor sleep.
fn stop(state: &mut State) {
    if let Some(t) = state.starting.take() {
        t.abort();
    }
    if let Some(s) = state.socks.take() {
        s.abort();
    }
    if let Some(tor) = &state.tor {
        tor.sleep();
    }
}

async fn serve(listener: TcpListener, tor: Arc<Tor>) {
    while let Ok((client, _)) = listener.accept().await {
        let tor = tor.clone();
        tokio::spawn(async move {
            if let Err(e) = crate::socks::handle(client, &tor).await {
                eprintln!("socks: {e}");
            }
        });
    }
}
