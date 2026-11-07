//! Torrent downloads with librqbit. They connect directly, not through Tor
//! (the Tor Project asks people not to run BitTorrent over Tor). A torrent is
//! known to the extension by its info hash, which survives restarts.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use librqbit::api::TorrentIdOrHash;
use librqbit::{AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent, Session, SessionOptions, SessionPersistenceConfig, TorrentStatsState};
use librqbit_core::hash_id::Id20;
use serde::Serialize;

/// What the extension sends to name a torrent: a magnet link or an http(s)
/// URL of a `.torrent` file (fetched by librqbit), or the file's bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    Url(String),
    File(Vec<u8>),
}

/// Name, size and file count, for the confirm window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TorrentInfo {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub files: usize,
    pub folder: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TorrentState {
    Starting,
    Downloading,
    Seeding,
    Paused,
    Error,
}

/// One row of the Downloads tab.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub id: String,
    pub name: String,
    pub done: u64,
    pub size: u64,
    /// Bytes per second.
    pub down_rate: u64,
    pub up_rate: u64,
    pub state: TorrentState,
    pub error: Option<String>,
}

/// A librqbit speed in MiB/s as bytes per second.
fn bytes_per_second(mibps: f64) -> u64 {
    (mibps * 1024.0 * 1024.0).round().max(0.0) as u64
}

/// The row state from librqbit's state and whether all bytes are there.
pub fn state_for(stats: &TorrentStatsState, finished: bool, error: bool) -> TorrentState {
    if error {
        return TorrentState::Error;
    }
    match stats {
        TorrentStatsState::Initializing { .. } => TorrentState::Starting,
        TorrentStatsState::Paused => TorrentState::Paused,
        TorrentStatsState::Error => TorrentState::Error,
        TorrentStatsState::Live if finished => TorrentState::Seeding,
        TorrentStatsState::Live => TorrentState::Downloading,
    }
}

/// What librqbit is asked about: a magnet, a `.torrent` link (fetched here,
/// through Tor's SOCKS port as `site` when `via` is set, never directly then),
/// or the file itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Link {
    Magnet(String),
    Web { url: String, via: Option<(u16, String)> },
    File(Vec<u8>),
}

/// The largest `.torrent` file fetched.
const MAX_TORRENT_FILE: usize = 32 * 1024 * 1024;
const FETCH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// The SOCKS proxy URL for the Tor helper's port, with `site` as the login so
/// the request uses that site's circuits.
fn tor_proxy_url(socks_port: u16, site: &str) -> anyhow::Result<reqwest::Url> {
    // socks5h: the name is resolved by Tor, not locally.
    let mut url = reqwest::Url::parse(&format!("socks5h://127.0.0.1:{socks_port}"))?;
    url.set_username(site).map_err(|_| anyhow::anyhow!("bad site name {site}"))?;
    url.set_password(Some("x")).map_err(|_| anyhow::anyhow!("bad site name {site}"))?;
    Ok(url)
}

/// Fetch a `.torrent` file: through the Tor helper's SOCKS port as `site`
/// when `via` is set (never directly then), else directly.
pub async fn fetch(url: &str, via: Option<(u16, &str)>) -> anyhow::Result<Vec<u8>> {
    let mut client = reqwest::Client::builder().timeout(FETCH_TIMEOUT);
    match via {
        Some((socks_port, site)) => client = client.proxy(reqwest::Proxy::all(tor_proxy_url(socks_port, site)?)?),
        // reqwest would otherwise honour HTTP(S)_PROXY from the environment.
        None => client = client.no_proxy(),
    }
    let mut res = client.build()?.get(url).send().await?.error_for_status()?;
    let mut body = Vec::new();
    while let Some(chunk) = res.chunk().await? {
        anyhow::ensure!(body.len() + chunk.len() <= MAX_TORRENT_FILE, "the .torrent file is larger than {} MB", MAX_TORRENT_FILE >> 20);
        body.extend_from_slice(&chunk);
    }
    // A .torrent file is a bencoded dictionary: anything else is most likely
    // a web page (a login, an error, an ordinary link).
    anyhow::ensure!(body.first() == Some(&b'd'), "that link didn't give a .torrent file (the site sent something else, perhaps a web page)");
    Ok(body)
}

/// A torrent looked up for the confirm window, kept for its Download.
#[derive(Debug, Clone)]
struct Prepared {
    at: Instant,
    bytes: Vec<u8>,
    /// A magnet's trackers and the peers that described it, so the download
    /// doesn't search from scratch.
    trackers: Vec<String>,
    peers: Vec<SocketAddr>,
}

/// How long a looked-up torrent waits for its Download, and how many wait.
const PREPARED_FOR: Duration = Duration::from_secs(30 * 60);
const MAX_PREPARED: usize = 16;

/// Looked-up torrents by link, so Download doesn't fetch the file (or ask
/// the swarm) a second time.
#[derive(Default)]
struct PreparedMap(HashMap<String, Prepared>);

impl PreparedMap {
    fn put(&mut self, key: String, p: Prepared, now: Instant) {
        self.0.retain(|_, v| now.duration_since(v.at) < PREPARED_FOR);
        if !self.0.contains_key(&key) && self.0.len() >= MAX_PREPARED {
            let oldest = self.0.iter().min_by_key(|(_, v)| v.at).map(|(k, _)| k.clone());
            if let Some(k) = oldest {
                self.0.remove(&k);
            }
        }
        self.0.insert(key, p);
    }

    fn take(&mut self, key: &str, now: Instant) -> Option<Prepared> {
        self.0.remove(key).filter(|p| now.duration_since(p.at) < PREPARED_FOR)
    }
}

fn parse_id(id: &str) -> anyhow::Result<TorrentIdOrHash> {
    Ok(TorrentIdOrHash::Hash(Id20::from_str(id).map_err(|e| anyhow::anyhow!("bad torrent id {id}: {e}"))?))
}


/// How long a torrent may take to describe itself (a magnet needs peers).
const INSPECT_WITHIN: std::time::Duration = std::time::Duration::from_secs(180);

/// Seeding stops once a finished torrent has shared this many copies of itself
/// since it last started: fair to the swarm, without showing the user's IP to
/// it for as long as the browser runs.
const SHARE_RATIO: u64 = 1;

/// Should a torrent stop sharing? Finished, live, and has given back enough
/// since it last started: `uploaded` counted from `baseline`, the count when
/// it was resumed (librqbit 9 starts it at zero then, but needn't).
pub fn shared_enough(stats: &TorrentStatsState, finished: bool, uploaded: u64, baseline: u64, size: u64) -> bool {
    matches!(stats, TorrentStatsState::Live) && finished && size > 0 && uploaded.saturating_sub(baseline) >= size.saturating_mul(SHARE_RATIO)
}

pub struct Torrents {
    session: Arc<Session>,
    folder: PathBuf,
    /// Held while the session is open: a second helper (another browser)
    /// would write the same downloads and state.
    _lock: std::fs::File,
    prepared: Mutex<PreparedMap>,
    /// Uploaded bytes when each torrent was last resumed, by info hash.
    baselines: Mutex<HashMap<String, u64>>,
}

impl Torrents {
    /// Open the session: files go to `folder`, the list of torrents is kept in
    /// `state_dir` and resumed on the next start.
    pub async fn open(folder: PathBuf, state_dir: PathBuf) -> anyhow::Result<Self> {
        Self::open_with(folder, state_dir, SessionOptions::default()).await
    }

    async fn open_with(folder: PathBuf, state_dir: PathBuf, opts: SessionOptions) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&folder)?;
        std::fs::create_dir_all(&state_dir)?;
        let lock = std::fs::File::create(state_dir.join("lock"))?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => anyhow::bail!(
                "Tortuga's downloads are open in another browser. Close that browser (or remove its downloads) to download here."
            ),
            Err(std::fs::TryLockError::Error(e)) => return Err(e.into()),
        }
        let opts = SessionOptions {
            persistence: Some(SessionPersistenceConfig::Json { folder: Some(state_dir) }),
            fastresume: true,
            ..opts
        };
        let session = Session::new_with_opts(folder.clone(), opts).await?;
        Ok(Self { session, folder, _lock: lock, prepared: Mutex::default(), baselines: Mutex::default() })
    }

    /// Describe the torrent without downloading it: a `.torrent` link is
    /// fetched, a magnet asks peers. What was found is kept for `add`.
    pub async fn inspect(&self, link: Link) -> anyhow::Result<TorrentInfo> {
        tokio::time::timeout(INSPECT_WITHIN, self.inspect_now(link))
            .await
            .map_err(|_| anyhow::anyhow!("nothing described this torrent within {} minutes: the link may be dead", INSPECT_WITHIN.as_secs() / 60))?
    }

    async fn inspect_now(&self, link: Link) -> anyhow::Result<TorrentInfo> {
        let (key, add, trackers) = match link {
            Link::Magnet(url) => {
                let trackers = librqbit_core::magnet::Magnet::parse(&url).map(|m| m.trackers).unwrap_or_default();
                (Some(url.clone()), AddTorrent::from_url(url), trackers)
            }
            Link::Web { url, via } => {
                let bytes = fetch(&url, via.as_ref().map(|(port, site)| (*port, site.as_str()))).await?;
                (Some(url), AddTorrent::from_bytes(bytes), Vec::new())
            }
            Link::File(bytes) => (None, AddTorrent::from_bytes(bytes), Vec::new()),
        };
        let opts = AddTorrentOptions { list_only: true, ..Default::default() };
        match self.session.add_torrent(add, Some(opts)).await? {
            AddTorrentResponse::ListOnly(r) => {
                if let Some(key) = key {
                    let p = Prepared { at: Instant::now(), bytes: r.torrent_bytes.to_vec(), trackers, peers: r.seen_peers.clone() };
                    self.prepared.lock().unwrap().put(key, p, Instant::now());
                }
                Ok(TorrentInfo {
                    id: r.info_hash.as_string(),
                    name: r.info.name().map(|n| n.into_owned()).unwrap_or_else(|| r.info_hash.as_string()),
                    size: r.info.iter_file_lengths().sum(),
                    files: r.info.iter_file_lengths().count(),
                    folder: self.folder.display().to_string(),
                })
            }
            AddTorrentResponse::AlreadyManaged(_, handle) | AddTorrentResponse::Added(_, handle) => Ok(self.info_of(&handle)),
        }
    }

    /// Start downloading, from what `inspect` found when it can; adding one
    /// that is already there just returns it.
    pub async fn add(&self, link: Link) -> anyhow::Result<TorrentInfo> {
        let key = match &link {
            Link::Magnet(url) | Link::Web { url, .. } => Some(url.clone()),
            Link::File(_) => None,
        };
        let prepared = key.and_then(|k| self.prepared.lock().unwrap().take(&k, Instant::now()));
        let (add, opts) = match (prepared, link) {
            (Some(p), _) => {
                let opts = AddTorrentOptions {
                    trackers: (!p.trackers.is_empty()).then_some(p.trackers),
                    initial_peers: (!p.peers.is_empty()).then_some(p.peers),
                    ..Default::default()
                };
                (AddTorrent::from_bytes(p.bytes), Some(opts))
            }
            (None, Link::Magnet(url)) => (AddTorrent::from_url(url), None),
            (None, Link::Web { url, via }) => (AddTorrent::from_bytes(fetch(&url, via.as_ref().map(|(p, s)| (*p, s.as_str()))).await?), None),
            (None, Link::File(bytes)) => (AddTorrent::from_bytes(bytes), None),
        };
        match self.session.add_torrent(add, opts).await? {
            AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => Ok(self.info_of(&handle)),
            AddTorrentResponse::ListOnly(_) => anyhow::bail!("librqbit answered list-only to a download"),
        }
    }

    pub async fn pause(&self, id: &str) -> anyhow::Result<()> {
        let handle = self.handle(id)?;
        self.session.pause(&handle).await
    }

    /// Resume it; a finished one then shares one more copy from now on.
    pub async fn resume(&self, id: &str) -> anyhow::Result<()> {
        let handle = self.handle(id)?;
        self.session.unpause(&handle).await?;
        self.baselines.lock().unwrap().insert(handle.info_hash().as_string(), handle.stats().uploaded_bytes);
        Ok(())
    }

    /// Stop it (and its seeding); with `delete_files` its files go too.
    pub async fn remove(&self, id: &str, delete_files: bool) -> anyhow::Result<()> {
        self.session.delete(parse_id(id)?, delete_files).await
    }

    /// Pause every torrent that has shared enough (see `SHARE_RATIO`).
    pub async fn stop_shared(&self) {
        let baselines = self.baselines.lock().unwrap().clone();
        let done: Vec<Arc<ManagedTorrent>> = self.session.with_torrents(|torrents| {
            torrents
                .filter(|(_, t)| {
                    let stats = t.stats();
                    let baseline = baselines.get(&t.info_hash().as_string()).copied().unwrap_or(0);
                    shared_enough(&stats.state, stats.finished, stats.uploaded_bytes, baseline, stats.total_bytes)
                })
                .map(|(_, t)| t.clone())
                .collect()
        });
        for t in done {
            let hash = t.info_hash().as_string();
            match self.session.pause(&t).await {
                Ok(()) => drop(self.baselines.lock().unwrap().remove(&hash)),
                Err(e) => eprintln!("couldn't stop sharing {hash}: {e:#}"),
            }
        }
    }

    /// A row for every torrent, in the order they were added.
    pub fn progress(&self) -> Vec<Progress> {
        self.session.with_torrents(|torrents| {
            torrents
                .map(|(_, t)| {
                    let stats = t.stats();
                    let (down_rate, up_rate) = stats
                        .live
                        .as_ref()
                        .map(|l| (bytes_per_second(l.download_speed.mbps), bytes_per_second(l.upload_speed.mbps)))
                        .unwrap_or((0, 0));
                    Progress {
                        id: t.info_hash().as_string(),
                        name: t.name().unwrap_or_else(|| t.info_hash().as_string()),
                        done: stats.progress_bytes,
                        size: stats.total_bytes,
                        down_rate,
                        up_rate,
                        state: state_for(&stats.state, stats.finished, stats.error.is_some()),
                        error: stats.error.clone(),
                    }
                })
                .collect()
        })
    }

    fn handle(&self, id: &str) -> anyhow::Result<Arc<ManagedTorrent>> {
        self.session.get(parse_id(id)?).ok_or_else(|| anyhow::anyhow!("no torrent {id}"))
    }

    /// Size and file count come from the metadata: the stats are empty while
    /// a torrent is still starting.
    fn info_of(&self, handle: &ManagedTorrent) -> TorrentInfo {
        let (size, files) = handle
            .with_metadata(|m| (m.info.iter_file_lengths().sum(), m.info.iter_file_lengths().count()))
            .unwrap_or((handle.stats().total_bytes, 0));
        TorrentInfo {
            id: handle.info_hash().as_string(),
            name: handle.name().unwrap_or_else(|| handle.info_hash().as_string()),
            size,
            files,
            folder: self.folder.display().to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rates_in_bytes_per_second() {
        assert_eq!(bytes_per_second(1.0), 1_048_576);
        assert_eq!(bytes_per_second(0.0), 0);
    }

    #[test]
    fn states() {
        assert_eq!(state_for(&TorrentStatsState::Initializing { paused: false }, false, false), TorrentState::Starting);
        assert_eq!(state_for(&TorrentStatsState::Live, false, false), TorrentState::Downloading);
        assert_eq!(state_for(&TorrentStatsState::Live, true, false), TorrentState::Seeding);
        assert_eq!(state_for(&TorrentStatsState::Paused, false, false), TorrentState::Paused);
        assert_eq!(state_for(&TorrentStatsState::Live, false, true), TorrentState::Error);
    }

    #[test]
    fn sharing_stops_after_one_copy() {
        let live = TorrentStatsState::Live;
        assert!(!shared_enough(&live, true, 99, 0, 100));
        assert!(shared_enough(&live, true, 100, 0, 100));
        // Still downloading, paused already, or empty: nothing to stop.
        assert!(!shared_enough(&live, false, 500, 0, 100));
        assert!(!shared_enough(&TorrentStatsState::Paused, true, 500, 0, 100));
        assert!(!shared_enough(&live, true, 0, 0, 0));
        // "Share again" right after a stop: counted from the resume, so it
        // shares one more copy instead of stopping again at once.
        assert!(!shared_enough(&live, true, 150, 100, 100));
        assert!(shared_enough(&live, true, 200, 100, 100));
    }

    fn prepared(at: Instant) -> Prepared {
        Prepared { at, bytes: b"d4:infoe".to_vec(), trackers: vec![], peers: vec![] }
    }

    #[test]
    fn a_looked_up_torrent_waits_for_its_download() {
        let now = Instant::now();
        let mut m = PreparedMap::default();
        m.put("magnet:?xt=a".into(), prepared(now), now);
        assert!(m.take("magnet:?xt=a", now).is_some());
        // Taken once: a second Download looks it up again.
        assert!(m.take("magnet:?xt=a", now).is_none());
        // Too old: looked up again.
        m.put("magnet:?xt=b".into(), prepared(now), now);
        assert!(m.take("magnet:?xt=b", now + PREPARED_FOR).is_none());
    }

    #[test]
    fn looked_up_torrents_stay_bounded() {
        let now = Instant::now();
        let mut m = PreparedMap::default();
        for i in 0..MAX_PREPARED + 3 {
            m.put(format!("k{i}"), prepared(now + Duration::from_secs(i as u64)), now);
        }
        assert_eq!(m.0.len(), MAX_PREPARED);
        // The oldest went first.
        assert!(m.take("k0", now).is_none());
        assert!(m.take(&format!("k{}", MAX_PREPARED + 2), now).is_some());
    }

    #[test]
    fn ids_are_info_hashes() {
        assert!(parse_id("cab507494d02ebb1178b38f2e9d7be299c86b862").is_ok());
        assert!(parse_id("not-a-hash").is_err());
    }

    #[test]
    fn proxy_login_names_the_site() {
        let url = tor_proxy_url(9150, "github.com").unwrap();
        assert_eq!(url.as_str(), "socks5h://github.com:x@127.0.0.1:9150");
        // An IPv6 site still makes a valid login.
        assert!(tor_proxy_url(9150, "2001:db8::1").is_ok());
    }

    /// A web server on localhost answering every request with `body`.
    async fn web_server(body: &'static [u8]) -> u16 {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf).await;
                let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = s.write_all(head.as_bytes()).await;
                let _ = s.write_all(body).await;
            }
        });
        port
    }

    /// Stands in for Tor: connects straight to the target, records who asked.
    #[derive(Clone, Default)]
    struct DirectConnector(Arc<std::sync::Mutex<Vec<crate::socks::SocksRequest>>>);

    impl crate::socks::Connector for DirectConnector {
        type Stream = tokio::net::TcpStream;
        fn connect(&self, req: crate::socks::SocksRequest) -> impl std::future::Future<Output = std::io::Result<Self::Stream>> + Send {
            self.0.lock().unwrap().push(req.clone());
            async move { tokio::net::TcpStream::connect((req.host.as_str(), req.port)).await }
        }
    }

    #[tokio::test]
    async fn fetches_through_the_socks_port_as_the_site() {
        let web = web_server(b"d4:infoe").await;
        let socks = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let socks_port = socks.local_addr().unwrap().port();
        let connector = DirectConnector::default();
        let seen = connector.0.clone();
        tokio::spawn(async move {
            while let Ok((client, _)) = socks.accept().await {
                let c = connector.clone();
                tokio::spawn(async move { crate::socks::handle(client, &c).await });
            }
        });
        let body = fetch(&format!("http://127.0.0.1:{web}/a.torrent"), Some((socks_port, "example.org"))).await.unwrap();
        assert_eq!(body, b"d4:infoe");
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].site, "example.org");
        assert_eq!(seen[0].port, web);
    }

    #[tokio::test]
    async fn fetching_through_tor_never_falls_back_to_direct() {
        // The site is up, but nothing listens on the SOCKS port: the fetch
        // must fail rather than reach the site directly.
        let web = web_server(b"d4:infoe").await;
        assert!(fetch(&format!("http://127.0.0.1:{web}/a.torrent"), Some((1, "example.org"))).await.is_err());
    }

    #[tokio::test]
    async fn a_web_page_is_not_a_torrent() {
        let web = web_server(b"<!doctype html><title>Login</title>").await;
        let e = fetch(&format!("http://127.0.0.1:{web}/download?id=42"), None).await.unwrap_err();
        assert!(e.to_string().contains("didn't give a .torrent file"));
        let web = web_server(b"d4:infoe").await;
        assert_eq!(fetch(&format!("http://127.0.0.1:{web}/download?id=42"), None).await.unwrap(), b"d4:infoe");
    }

    #[tokio::test]
    async fn a_session_starts_empty_and_rejects_unknown_ids() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        // No DHT, no listening port, no local discovery: nothing touches the network.
        let offline = SessionOptions { dht: None, listen: None, disable_local_service_discovery: true, ..Default::default() };
        let t = Torrents::open_with(dir.join("files"), dir.join("state"), offline).await.unwrap();
        assert!(t.progress().is_empty());
        assert!(t.pause("cab507494d02ebb1178b38f2e9d7be299c86b862").await.is_err());
        t.stop_shared().await;
        // A second helper (another browser) can't open the same downloads.
        let offline = SessionOptions { dht: None, listen: None, disable_local_service_discovery: true, ..Default::default() };
        let second = Torrents::open_with(dir.join("files"), dir.join("state"), offline).await;
        assert!(second.err().unwrap().to_string().contains("another browser"));
        drop(t);
    }
}
