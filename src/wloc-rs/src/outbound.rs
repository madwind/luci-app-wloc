use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::os::fd::AsRawFd;

use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::{TcpStream, UdpSocket};

use crate::config::Outbound;

const OUTBOUND_NAMESPACE_MARK: u32 = 0x20000000;

fn set_socket_mark(socket: &Socket, mark: u32) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        let mark = mark as libc::c_uint;
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_MARK,
                (&mark as *const libc::c_uint).cast(),
                std::mem::size_of_val(&mark) as libc::socklen_t,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (socket, mark);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "WLOC outbound marks require Linux",
        ))
    }
}

async fn connect_marked(destination: SocketAddr, mark: u32) -> io::Result<TcpStream> {
    let socket = Socket::new(
        Domain::for_address(destination),
        Type::STREAM,
        Some(Protocol::TCP),
    )?;
    set_socket_mark(&socket, mark)?;
    socket.set_nonblocking(true)?;
    match socket.connect(&destination.into()) {
        Ok(()) => {}
        Err(error) if error.raw_os_error() == Some(libc::EINPROGRESS) => {}
        Err(error) => return Err(error),
    }
    let stream = TcpStream::from_std(socket.into())?;
    stream.writable().await?;
    if let Some(error) = stream.take_error()? {
        return Err(error);
    }
    stream.set_nodelay(true)?;
    Ok(stream)
}

pub async fn connect_tcp_addr(
    outbound: &Outbound,
    destination: SocketAddr,
) -> io::Result<TcpStream> {
    match outbound {
        Outbound::Direct => {
            let stream = TcpStream::connect(destination).await?;
            stream.set_nodelay(true)?;
            Ok(stream)
        }
        Outbound::Tproxy { mark, .. } => {
            connect_marked(destination, OUTBOUND_NAMESPACE_MARK | *mark).await
        }
    }
}

pub fn bind_udp(outbound: &Outbound, family: SocketAddr) -> io::Result<UdpSocket> {
    let (socket, bind_address) = match family {
        SocketAddr::V4(_) => (
            Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?,
            SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)),
        ),
        SocketAddr::V6(_) => {
            let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
            socket.set_only_v6(true)?;
            (
                socket,
                SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, 0, 0, 0)),
            )
        }
    };
    if let Outbound::Tproxy { mark, .. } = outbound {
        set_socket_mark(&socket, OUTBOUND_NAMESPACE_MARK | *mark)?;
    }
    socket.bind(&bind_address.into())?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}
