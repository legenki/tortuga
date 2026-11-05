//! tortuga-helper: the native messaging host the Tortuga extension starts.
//! stdin/stdout carry framed JSON messages; logs go to stderr only.

mod app;
mod config;
mod framing;
mod hops;
mod isolation;
mod protocol;
mod socks;
mod tor;
mod torrents;

use protocol::{ErrorCode, Message, Request};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (events, mut outbox) = tokio::sync::mpsc::unbounded_channel::<Message>();

    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(m) = outbox.recv().await {
            let bytes = serde_json::to_vec(&m)?;
            framing::write_message(&mut stdout, &bytes).await?;
        }
        anyhow::Ok(())
    });

    let app = app::App::new(config::Paths::discover()?, events.clone());
    let mut stdin = tokio::io::stdin();
    // The browser closes stdin when the extension disconnects: then we exit,
    // taking Tor with us.
    while let Some(bytes) = framing::read_message(&mut stdin).await? {
        match serde_json::from_slice::<Request>(&bytes) {
            Ok(req) => app.handle(req).await,
            Err(e) => {
                let _ = events.send(Message::error(None, ErrorCode::BadRequest, e));
            }
        }
    }
    drop(app);
    drop(events);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), writer).await;
    Ok(())
}
