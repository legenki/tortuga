//! Torrent downloads with librqbit. They connect directly, not through Tor
//! (the Tor Project asks people not to run BitTorrent over Tor). A torrent is
//! known to the extension by its info hash, which survives restarts.

use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

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

fn parse_id(id: &str) -> anyhow::Result<TorrentIdOrHash> {
    Ok(TorrentIdOrHash::Hash(Id20::from_str(id).map_err(|e| anyhow::anyhow!("bad torrent id {id}: {e}"))?))
}

fn add_request(source: &Source) -> AddTorrent<'static> {
    match source {
        Source::Url(url) => AddTorrent::from_url(url.clone()),
        Source::File(bytes) => AddTorrent::from_bytes(bytes.clone()),
    }
}

pub struct Torrents {
    session: Arc<Session>,
    folder: PathBuf,
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
        let opts = SessionOptions {
            persistence: Some(SessionPersistenceConfig::Json { folder: Some(state_dir) }),
            fastresume: true,
            ..opts
        };
        let session = Session::new_with_opts(folder.clone(), opts).await?;
        Ok(Self { session, folder })
    }

    /// Fetch the torrent's metadata (from peers, for a magnet) without downloading.
    pub async fn inspect(&self, source: &Source) -> anyhow::Result<TorrentInfo> {
        let opts = AddTorrentOptions { list_only: true, ..Default::default() };
        match self.session.add_torrent(add_request(source), Some(opts)).await? {
            AddTorrentResponse::ListOnly(r) => Ok(TorrentInfo {
                id: r.info_hash.as_string(),
                name: r.info.name().map(|n| n.into_owned()).unwrap_or_else(|| r.info_hash.as_string()),
                size: r.info.iter_file_lengths().sum(),
                files: r.info.iter_file_lengths().count(),
                folder: self.folder.display().to_string(),
            }),
            AddTorrentResponse::AlreadyManaged(_, handle) | AddTorrentResponse::Added(_, handle) => Ok(self.info_of(&handle)),
        }
    }

    /// Start downloading; adding one that is already there just returns it.
    pub async fn add(&self, source: &Source) -> anyhow::Result<TorrentInfo> {
        match self.session.add_torrent(add_request(source), None).await? {
            AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => Ok(self.info_of(&handle)),
            AddTorrentResponse::ListOnly(_) => anyhow::bail!("librqbit answered list-only to a download"),
        }
    }

    pub async fn pause(&self, id: &str) -> anyhow::Result<()> {
        let handle = self.handle(id)?;
        self.session.pause(&handle).await
    }

    pub async fn resume(&self, id: &str) -> anyhow::Result<()> {
        let handle = self.handle(id)?;
        self.session.unpause(&handle).await
    }

    /// Stop it (and its seeding); with `delete_files` its files go too.
    pub async fn remove(&self, id: &str, delete_files: bool) -> anyhow::Result<()> {
        self.session.delete(parse_id(id)?, delete_files).await
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
    fn ids_are_info_hashes() {
        assert!(parse_id("cab507494d02ebb1178b38f2e9d7be299c86b862").is_ok());
        assert!(parse_id("not-a-hash").is_err());
    }

    #[tokio::test]
    async fn a_session_starts_empty_and_rejects_unknown_ids() {
        let dir = std::env::temp_dir().join(format!("tortuga-torrents-test-{}", std::process::id()));
        // No DHT, no listening port, no local discovery: nothing touches the network.
        let offline = SessionOptions { dht: None, listen: None, disable_local_service_discovery: true, ..Default::default() };
        let t = Torrents::open_with(dir.join("files"), dir.join("state"), offline).await.unwrap();
        assert!(t.progress().is_empty());
        assert!(t.pause("cab507494d02ebb1178b38f2e9d7be299c86b862").await.is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
