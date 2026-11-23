//! tortuga-helper: the native messaging host the Tortuga extension starts.
//! stdin/stdout carry framed JSON messages; logs go to stderr only.

mod app;
mod config;
mod framing;
mod hops;
mod isolation;
mod moat;
mod protocol;
mod socks;
mod tor;

use protocol::{ErrorCode, Message, Request};
use tokio::io::AsyncWrite;
use tokio::sync::mpsc::UnboundedReceiver;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (events, mut outbox) = tokio::sync::mpsc::unbounded_channel::<Message>();

    let writer = tokio::spawn(async move { pump(&mut outbox, &mut tokio::io::stdout()).await });

    let app = app::App::new(config::Paths::discover()?, events.clone());
    let mut stdin = tokio::io::stdin();
    // The browser closes stdin when the extension disconnects: then we exit,
    // taking Tor with us.
    while let Some(bytes) = framing::read_message(&mut stdin).await? {
        match serde_json::from_slice::<Request>(&bytes) {
            Ok(req) => app.handle(req).await,
            // Answer the request's id when it has one, so the extension
            // isn't left waiting (e.g. a newer extension's new request type).
            Err(e) => {
                let _ = events.send(unparsed_reply(&bytes, e));
            }
        }
    }
    drop(app);
    drop(events);
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), writer).await;
    Ok(())
}

/// The answer to a request that didn't parse. An extension up to 0.2.1 still
/// sends `torrent.*` requests; tell it why they fail instead of showing it a
/// serde error.
fn unparsed_reply(bytes: &[u8], e: serde_json::Error) -> Message {
    let id = protocol::id_of(bytes);
    if protocol::is_removed_torrent_request(bytes) {
        return Message::error(id, ErrorCode::BadRequest, TORRENTS_REMOVED);
    }
    Message::error(id, ErrorCode::BadRequest, e)
}

const TORRENTS_REMOVED: &str = "Torrent downloads were removed in Tortuga 0.3.0. Update the Tortuga extension.";

/// Write messages until the channel closes or the browser goes away. One
/// message that can't be sent doesn't silence the helper: a reply too large
/// for the browser is answered with an error instead.
async fn pump<W: AsyncWrite + Unpin>(outbox: &mut UnboundedReceiver<Message>, w: &mut W) -> std::io::Result<()> {
    while let Some(m) = outbox.recv().await {
        let bytes = match serde_json::to_vec(&m) {
            Ok(bytes) => bytes,
            Err(e) => {
                eprintln!("dropped a message that didn't serialize: {e}");
                continue;
            }
        };
        if bytes.len() > framing::MAX_TO_BROWSER {
            eprintln!("dropped a message of {} bytes: too large for the browser", bytes.len());
            if let Some(id) = m.id {
                let e = Message::error(Some(id), ErrorCode::Internal, "the answer is too large to send to the browser");
                framing::write_message(w, &serde_json::to_vec(&e)?).await?;
            }
            continue;
        }
        framing::write_message(w, &bytes).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::Outgoing;

    #[test]
    fn a_torrent_request_is_answered_with_a_plain_message() {
        let raw = br#"{"id":4,"type":"torrent.inspect","payload":{}}"#;
        let err = serde_json::from_slice::<Request>(raw).unwrap_err();
        let m = unparsed_reply(raw, err);
        assert_eq!(m.id, Some(4));
        match m.body {
            Outgoing::Error { code, message } => {
                assert!(matches!(code, ErrorCode::BadRequest));
                assert_eq!(message, TORRENTS_REMOVED);
            }
            _ => panic!("expected an error"),
        }
    }

    #[tokio::test]
    async fn an_oversized_reply_becomes_an_error_and_the_rest_still_go_out() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let huge = "x".repeat(framing::MAX_TO_BROWSER);
        tx.send(Message::error(Some(1), ErrorCode::TorFailed, huge)).unwrap();
        tx.send(Message::reply(2, Outgoing::Ok)).unwrap();
        drop(tx);
        let mut wire = Vec::new();
        pump(&mut rx, &mut wire).await.unwrap();
        let mut r = wire.as_slice();
        let first: serde_json::Value = serde_json::from_slice(&framing::read_message(&mut r).await.unwrap().unwrap()).unwrap();
        assert_eq!(first["id"], 1);
        assert_eq!(first["payload"]["code"], "internal");
        let second: serde_json::Value = serde_json::from_slice(&framing::read_message(&mut r).await.unwrap().unwrap()).unwrap();
        assert_eq!(second, serde_json::json!({"id": 2, "type": "ok"}));
    }
}
