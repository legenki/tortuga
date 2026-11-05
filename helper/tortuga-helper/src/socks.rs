//! A minimal SOCKS5 server (RFC 1928, CONNECT only) with username/password
//! auth (RFC 1929). The username names the site whose circuits a connection
//! uses; the password is ignored. No auth means the default site (Chrome).

use std::future::Future;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::isolation::DEFAULT_SITE;

pub const SUCCEEDED: u8 = 0x00;
pub const HOST_UNREACHABLE: u8 = 0x04;
pub const COMMAND_NOT_SUPPORTED: u8 = 0x07;
pub const ADDRESS_NOT_SUPPORTED: u8 = 0x08;

const NO_AUTH: u8 = 0x00;
const USER_PASS: u8 = 0x02;
const NO_ACCEPTABLE: u8 = 0xFF;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SocksRequest {
    pub site: String,
    pub host: String,
    pub port: u16,
}

/// Opens the outgoing side of a SOCKS connection.
pub trait Connector: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<Self::Stream>> + Send;
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_owned())
}

/// Run the SOCKS5 greeting, auth and request; return what was asked for.
/// On a request this server can't serve, the error reply is already sent.
pub async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> io::Result<SocksRequest> {
    let [ver, n] = [s.read_u8().await?, s.read_u8().await?];
    if ver != 5 {
        return Err(bad("not SOCKS5"));
    }
    let mut methods = vec![0u8; n as usize];
    s.read_exact(&mut methods).await?;

    let site = if methods.contains(&USER_PASS) {
        s.write_all(&[5, USER_PASS]).await?;
        if s.read_u8().await? != 1 {
            return Err(bad("bad auth version"));
        }
        let mut user = vec![0u8; s.read_u8().await? as usize];
        s.read_exact(&mut user).await?;
        let mut pass = vec![0u8; s.read_u8().await? as usize];
        s.read_exact(&mut pass).await?;
        s.write_all(&[1, 0]).await?;
        let user = String::from_utf8(user).map_err(|_| bad("username is not UTF-8"))?;
        if user.is_empty() { DEFAULT_SITE.to_owned() } else { user }
    } else if methods.contains(&NO_AUTH) {
        s.write_all(&[5, NO_AUTH]).await?;
        DEFAULT_SITE.to_owned()
    } else {
        s.write_all(&[5, NO_ACCEPTABLE]).await?;
        return Err(bad("no acceptable auth method"));
    };

    let mut head = [0u8; 4];
    s.read_exact(&mut head).await?;
    let [ver, cmd, _rsv, atyp] = head;
    if ver != 5 {
        return Err(bad("not SOCKS5"));
    }
    if cmd != 1 {
        reply(s, COMMAND_NOT_SUPPORTED).await?;
        return Err(bad("only CONNECT is supported"));
    }
    let host = match atyp {
        1 => {
            let mut a = [0u8; 4];
            s.read_exact(&mut a).await?;
            Ipv4Addr::from(a).to_string()
        }
        3 => {
            let mut name = vec![0u8; s.read_u8().await? as usize];
            s.read_exact(&mut name).await?;
            String::from_utf8(name).map_err(|_| bad("host name is not UTF-8"))?
        }
        4 => {
            let mut a = [0u8; 16];
            s.read_exact(&mut a).await?;
            Ipv6Addr::from(a).to_string()
        }
        _ => {
            reply(s, ADDRESS_NOT_SUPPORTED).await?;
            return Err(bad("unknown address type"));
        }
    };
    let port = s.read_u16().await?;
    Ok(SocksRequest { site, host, port })
}

/// Send a reply with `code` and an all-zero bound address.
pub async fn reply<S: AsyncWrite + Unpin>(s: &mut S, code: u8) -> io::Result<()> {
    s.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    s.flush().await
}

/// Serve one client: handshake, connect through `connector`, then relay bytes
/// both ways until either side closes.
pub async fn handle<S, C>(mut client: S, connector: &C) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
    C: Connector,
{
    let req = handshake(&mut client).await?;
    match connector.connect(req).await {
        Ok(mut upstream) => {
            reply(&mut client, SUCCEEDED).await?;
            match tokio::io::copy_bidirectional(&mut client, &mut upstream).await {
                // Arti reports a stream the far end already closed as "not
                // connected" when we shut it down: that's a normal end.
                Err(e) if e.kind() != io::ErrorKind::NotConnected => Err(e),
                _ => Ok(()),
            }
        }
        Err(e) => {
            reply(&mut client, HOST_UNREACHABLE).await?;
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{DuplexStream, duplex};

    /// Records requests; answers with one end of a pipe whose other end echoes.
    #[derive(Default)]
    struct EchoConnector {
        seen: Arc<Mutex<Vec<SocksRequest>>>,
        fail: bool,
    }

    impl Connector for EchoConnector {
        type Stream = DuplexStream;
        fn connect(&self, req: SocksRequest) -> impl Future<Output = io::Result<DuplexStream>> + Send {
            self.seen.lock().unwrap().push(req);
            let fail = self.fail;
            async move {
                if fail {
                    return Err(io::Error::other("unreachable"));
                }
                let (ours, mut theirs) = duplex(1024);
                tokio::spawn(async move {
                    let mut buf = [0u8; 64];
                    while let Ok(n) = theirs.read(&mut buf).await {
                        if n == 0 || theirs.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                });
                Ok(ours)
            }
        }
    }

    fn user_pass_hello(user: &str) -> Vec<u8> {
        let mut v = vec![5, 1, USER_PASS, 1, user.len() as u8];
        v.extend_from_slice(user.as_bytes());
        v.extend_from_slice(&[1, b'x']);
        v
    }

    fn connect_domain(host: &str, port: u16) -> Vec<u8> {
        let mut v = vec![5, 1, 0, 3, host.len() as u8];
        v.extend_from_slice(host.as_bytes());
        v.extend_from_slice(&port.to_be_bytes());
        v
    }

    #[tokio::test]
    async fn username_names_the_site() {
        let (mut client, mut server) = duplex(1024);
        let mut bytes = user_pass_hello("github.com");
        bytes.extend(connect_domain("api.github.com", 443));
        client.write_all(&bytes).await.unwrap();
        let req = handshake(&mut server).await.unwrap();
        assert_eq!(req, SocksRequest { site: "github.com".into(), host: "api.github.com".into(), port: 443 });
        let mut answer = [0u8; 4];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer, [5, USER_PASS, 1, 0]);
    }

    #[tokio::test]
    async fn no_auth_uses_default_site() {
        let (mut client, mut server) = duplex(1024);
        let mut bytes = vec![5, 1, NO_AUTH];
        bytes.extend([5, 1, 0, 1, 93, 184, 216, 34, 0, 80]);
        client.write_all(&bytes).await.unwrap();
        let req = handshake(&mut server).await.unwrap();
        assert_eq!(req, SocksRequest { site: DEFAULT_SITE.into(), host: "93.184.216.34".into(), port: 80 });
    }

    #[tokio::test]
    async fn bind_is_refused() {
        let (mut client, mut server) = duplex(1024);
        client.write_all(&[5, 1, NO_AUTH, 5, 2, 0, 1, 0, 0, 0, 0, 0, 80]).await.unwrap();
        assert!(handshake(&mut server).await.is_err());
        let mut answer = [0u8; 12];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(&answer[2..4], &[5, COMMAND_NOT_SUPPORTED]);
    }

    #[tokio::test]
    async fn relays_bytes_after_connect() {
        let connector = EchoConnector::default();
        let seen = connector.seen.clone();
        let (mut client, server) = duplex(1024);
        let task = tokio::spawn(async move { handle(server, &connector).await });
        let mut bytes = user_pass_hello("example.com");
        bytes.extend(connect_domain("example.com", 80));
        client.write_all(&bytes).await.unwrap();
        let mut answer = [0u8; 4 + 10];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer[5], SUCCEEDED);
        client.write_all(b"ping").await.unwrap();
        let mut echo = [0u8; 4];
        client.read_exact(&mut echo).await.unwrap();
        assert_eq!(&echo, b"ping");
        drop(client);
        let _ = task.await;
        assert_eq!(seen.lock().unwrap()[0].site, "example.com");
    }

    #[tokio::test]
    async fn failed_connect_replies_host_unreachable() {
        let connector = EchoConnector { fail: true, ..Default::default() };
        let (mut client, server) = duplex(1024);
        let task = tokio::spawn(async move { handle(server, &connector).await });
        let mut bytes = vec![5, 1, NO_AUTH];
        bytes.extend(connect_domain("example.com", 80));
        client.write_all(&bytes).await.unwrap();
        let mut answer = [0u8; 2 + 10];
        client.read_exact(&mut answer).await.unwrap();
        assert_eq!(answer[3], HOST_UNREACHABLE);
        assert!(task.await.unwrap().is_err());
    }
}
