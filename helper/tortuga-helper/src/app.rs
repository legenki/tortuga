//! Handles requests from the extension: hello, then Tor (start, stop, new
//! circuit) and torrents. Long work runs in tasks, so a `tor.stop` can cancel
//! a start and a slow magnet lookup doesn't hold up other requests.
//!
//! The extension uses one helper process for Tor and another for torrents
//! (two native ports), so each part is opened only when first asked for.

use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tokio::sync::{Mutex, OnceCell};
use tokio::task::JoinHandle;

use crate::config::{Paths, default_snowflake_lines, tor_config};
use crate::moat::{self, LineKind, Route};
use crate::protocol::{BridgeChoice, ErrorCode, Message, Outgoing, PROTOCOL_VERSION, Request, RequestBody, SourceMsg};
use crate::tor::{Events, Tor};
use crate::torrents::Torrents;

/// How often the Downloads tab gets fresh numbers.
const PROGRESS_EVERY: Duration = Duration::from_secs(1);

/// A torrent request, run in its own task.
enum TorrentJob {
    Inspect(SourceMsg),
    Add(SourceMsg),
    Pause(String),
    Resume(String),
    Remove(String, bool),
}

#[derive(Default)]
struct State {
    hello: bool,
    tor: Option<Arc<Tor>>,
    /// The bootstrap in progress, if any.
    starting: Option<JoinHandle<()>>,
    /// The SOCKS listener while Tor is on, and its port.
    socks: Option<JoinHandle<()>>,
    socks_port: Option<u16>,
}

#[derive(Clone)]
pub struct App {
    state: Arc<Mutex<State>>,
    paths: Paths,
    events: Events,
    torrents: Arc<OnceCell<Arc<Torrents>>>,
}

impl App {
    pub fn new(paths: Paths, events: Events) -> Self {
        Self { state: Arc::default(), paths, events, torrents: Arc::default() }
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
            RequestBody::TorrentInspect { source } => self.torrent(req.id, TorrentJob::Inspect(source)),
            RequestBody::TorrentAdd { source } => self.torrent(req.id, TorrentJob::Add(source)),
            RequestBody::TorrentPause { id } => self.torrent(req.id, TorrentJob::Pause(id)),
            RequestBody::TorrentResume { id } => self.torrent(req.id, TorrentJob::Resume(id)),
            RequestBody::TorrentRemove { id, delete_files } => self.torrent(req.id, TorrentJob::Remove(id, delete_files)),
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

    fn torrent(&self, id: u64, job: TorrentJob) {
        let app = self.clone();
        tokio::spawn(async move {
            let reply = match app.run_torrent(job).await {
                Ok(body) => Message::reply(id, body),
                Err(e) => Message::error(Some(id), ErrorCode::TorrentFailed, format!("{e:#}")),
            };
            app.send(reply);
        });
    }

    async fn run_torrent(&self, job: TorrentJob) -> anyhow::Result<Outgoing> {
        let torrents = self.open_torrents().await?;
        Ok(match job {
            TorrentJob::Inspect(source) => Outgoing::TorrentInfo(torrents.inspect(&source.decode()?).await?),
            TorrentJob::Add(source) => Outgoing::TorrentInfo(torrents.add(&source.decode()?).await?),
            TorrentJob::Pause(id) => torrents.pause(&id).await.map(|_| Outgoing::Ok)?,
            TorrentJob::Resume(id) => torrents.resume(&id).await.map(|_| Outgoing::Ok)?,
            TorrentJob::Remove(id, delete_files) => torrents.remove(&id, delete_files).await.map(|_| Outgoing::Ok)?,
        })
    }

    /// The torrent session, opened (and its saved downloads resumed) on first use.
    async fn open_torrents(&self) -> anyhow::Result<Arc<Torrents>> {
        let torrents = self
            .torrents
            .get_or_try_init(|| async {
                let t = Arc::new(Torrents::open(self.paths.downloads.clone(), self.paths.torrent_state.clone()).await?);
                tokio::spawn(report_progress(t.clone(), self.events.clone()));
                anyhow::Ok(t)
            })
            .await?;
        Ok(torrents.clone())
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
        state.socks_port = Some(port);
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
    state.socks_port = None;
    if let Some(tor) = &state.tor {
        tor.sleep();
    }
}

/// Send the torrent list every second while there is something to show, and
/// once more when it becomes empty.
async fn report_progress(torrents: Arc<Torrents>, events: Events) {
    let mut last_empty = false;
    loop {
        let list = torrents.progress();
        let empty = list.is_empty();
        if !(empty && last_empty) && events.send(Message::event(Outgoing::TorrentProgress { torrents: list })).is_err() {
            return;
        }
        last_empty = empty;
        tokio::time::sleep(PROGRESS_EVERY).await;
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
