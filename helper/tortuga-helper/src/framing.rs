//! Native messaging framing: a 32-bit length in native byte order, then that
//! many bytes of UTF-8 JSON. Browsers cap host → browser messages at 1 MiB.

use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Largest message the browser accepts from the helper.
pub const MAX_TO_BROWSER: usize = 1024 * 1024;
/// Largest message the browser can send (Chrome and Firefox: 64 MiB).
pub const MAX_FROM_BROWSER: usize = 64 * 1024 * 1024;

/// Read one message. `Ok(None)` when the browser closed the pipe.
pub async fn read_message<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let n = u32::from_ne_bytes(len) as usize;
    if n > MAX_FROM_BROWSER {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("message of {n} bytes is too large")));
    }
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf).await?;
    Ok(Some(buf))
}

/// Write one message and flush it.
pub async fn write_message<W: AsyncWrite + Unpin>(w: &mut W, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX_TO_BROWSER {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("message of {} bytes is too large", body.len())));
    }
    w.write_all(&(body.len() as u32).to_ne_bytes()).await?;
    w.write_all(body).await?;
    w.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip() {
        let mut wire = Vec::new();
        write_message(&mut wire, br#"{"id":1}"#).await.unwrap();
        write_message(&mut wire, b"{}").await.unwrap();
        let mut r = wire.as_slice();
        assert_eq!(read_message(&mut r).await.unwrap().unwrap(), br#"{"id":1}"#);
        assert_eq!(read_message(&mut r).await.unwrap().unwrap(), b"{}");
        assert!(read_message(&mut r).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn length_is_native_endian_u32() {
        let mut wire = Vec::new();
        write_message(&mut wire, b"abc").await.unwrap();
        assert_eq!(&wire[..4], &3u32.to_ne_bytes());
    }

    #[tokio::test]
    async fn refuses_oversized_outgoing() {
        let mut wire = Vec::new();
        let big = vec![b'x'; MAX_TO_BROWSER + 1];
        assert!(write_message(&mut wire, &big).await.is_err());
        assert!(wire.is_empty());
    }

    #[tokio::test]
    async fn truncated_body_is_an_error() {
        let mut wire = 10u32.to_ne_bytes().to_vec();
        wire.extend_from_slice(b"short");
        assert!(read_message(&mut wire.as_slice()).await.is_err());
    }
}
