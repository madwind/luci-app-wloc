use tokio::net::TcpStream;

const MAX_CLIENT_HELLO: usize = 64 * 1024;

#[derive(Debug)]
pub enum HelloError {
    Incomplete,
    NotTls,
    Malformed,
}

fn be16(bytes: &[u8], at: usize) -> Result<usize, HelloError> {
    let data = bytes.get(at..at + 2).ok_or(HelloError::Incomplete)?;
    Ok(u16::from_be_bytes([data[0], data[1]]) as usize)
}

/// Parse SNI from the first TLS ClientHello without consuming stream bytes.
pub fn parse_sni(bytes: &[u8]) -> Result<Option<String>, HelloError> {
    let mut handshake = Vec::new();
    let mut offset = 0_usize;
    let expected = loop {
        if bytes.len().saturating_sub(offset) < 5 {
            return Err(HelloError::Incomplete);
        }
        if bytes[offset] != 22 {
            return Err(if offset == 0 {
                HelloError::NotTls
            } else {
                HelloError::Malformed
            });
        }
        let record_len = be16(bytes, offset + 3)?;
        if record_len > MAX_CLIENT_HELLO {
            return Err(HelloError::Malformed);
        }
        let start = offset + 5;
        let end = start.checked_add(record_len).ok_or(HelloError::Malformed)?;
        if end > bytes.len() {
            return Err(HelloError::Incomplete);
        }
        handshake.extend_from_slice(&bytes[start..end]);
        if handshake.len() > MAX_CLIENT_HELLO {
            return Err(HelloError::Malformed);
        }
        if handshake.len() >= 4 {
            if handshake[0] != 1 {
                return Err(HelloError::NotTls);
            }
            let length = (usize::from(handshake[1]) << 16)
                | (usize::from(handshake[2]) << 8)
                | usize::from(handshake[3]);
            let expected = 4_usize.checked_add(length).ok_or(HelloError::Malformed)?;
            if expected > MAX_CLIENT_HELLO {
                return Err(HelloError::Malformed);
            }
            if handshake.len() >= expected {
                break expected;
            }
        }
        offset = end;
    };
    let bytes = &handshake[..expected];
    let mut p = 0;
    if *bytes.get(p).ok_or(HelloError::Incomplete)? != 1 {
        return Err(HelloError::NotTls);
    }
    p += 4; // handshake type + u24 length
    p += 2 + 32; // version + random
    let sid = *bytes.get(p).ok_or(HelloError::Incomplete)? as usize;
    p += 1 + sid;
    let ciphers = be16(bytes, p)?;
    p += 2 + ciphers;
    let compression = *bytes.get(p).ok_or(HelloError::Incomplete)? as usize;
    p += 1 + compression;
    let extensions_len = be16(bytes, p)?;
    p += 2;
    let extensions_end = p.checked_add(extensions_len).ok_or(HelloError::Malformed)?;
    if extensions_end > bytes.len() {
        return Err(HelloError::Incomplete);
    }
    while p + 4 <= extensions_end {
        let kind = be16(bytes, p)?;
        let len = be16(bytes, p + 2)?;
        p += 4;
        let end = p.checked_add(len).ok_or(HelloError::Malformed)?;
        if end > extensions_end {
            return Err(HelloError::Malformed);
        }
        if kind == 0 {
            let list_len = be16(bytes, p)?;
            let mut q = p + 2;
            let list_end = q.checked_add(list_len).ok_or(HelloError::Malformed)?;
            if list_end > end {
                return Err(HelloError::Malformed);
            }
            while q + 3 <= list_end {
                let name_type = bytes[q];
                let name_len = be16(bytes, q + 1)?;
                q += 3;
                let name_end = q.checked_add(name_len).ok_or(HelloError::Malformed)?;
                if name_end > list_end {
                    return Err(HelloError::Malformed);
                }
                if name_type == 0 {
                    let host = std::str::from_utf8(&bytes[q..name_end])
                        .map_err(|_| HelloError::Malformed)?;
                    if host.is_empty()
                        || host.len() > 253
                        || !host
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
                    {
                        return Err(HelloError::Malformed);
                    }
                    return Ok(Some(host.to_ascii_lowercase()));
                }
                q = name_end;
            }
            return Ok(None);
        }
        p = end;
    }
    Ok(None)
}

pub async fn peek_sni(stream: &TcpStream) -> Result<Option<String>, HelloError> {
    let mut buf = vec![0_u8; MAX_CLIENT_HELLO + 5];
    for _ in 0..20 {
        let count = stream
            .peek(&mut buf)
            .await
            .map_err(|_| HelloError::Malformed)?;
        if count == 0 {
            return Err(HelloError::Incomplete);
        }
        match parse_sni(&buf[..count]) {
            Err(HelloError::Incomplete) => {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await
            }
            result => return result,
        }
    }
    Err(HelloError::Incomplete)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client_hello(hostname: Option<&str>) -> Vec<u8> {
        let mut extensions = Vec::new();
        if let Some(hostname) = hostname {
            let mut names = vec![0];
            names.extend((hostname.len() as u16).to_be_bytes());
            names.extend(hostname.as_bytes());
            let mut sni = Vec::new();
            sni.extend((names.len() as u16).to_be_bytes());
            sni.extend(names);
            extensions.extend(0_u16.to_be_bytes());
            extensions.extend((sni.len() as u16).to_be_bytes());
            extensions.extend(sni);
        }
        let mut body = vec![3, 3];
        body.extend([0_u8; 32]);
        body.push(0);
        body.extend(2_u16.to_be_bytes());
        body.extend([0x13, 0x01]);
        body.extend([1, 0]);
        body.extend((extensions.len() as u16).to_be_bytes());
        body.extend(extensions);
        let mut handshake = vec![1];
        let len = body.len();
        handshake.extend([
            ((len >> 16) & 0xff) as u8,
            ((len >> 8) & 0xff) as u8,
            (len & 0xff) as u8,
        ]);
        handshake.extend(body);
        let mut record = vec![22, 3, 3];
        record.extend((handshake.len() as u16).to_be_bytes());
        record.extend(handshake);
        record
    }

    #[test]
    fn parses_normal_and_fragmented_client_hello() {
        let hello = client_hello(Some("GS-LOC.APPLE.COM"));
        assert_eq!(
            parse_sni(&hello).unwrap().as_deref(),
            Some("gs-loc.apple.com")
        );

        let payload = &hello[5..];
        let split = 18;
        let mut fragmented = vec![22, 3, 3];
        fragmented.extend((split as u16).to_be_bytes());
        fragmented.extend(&payload[..split]);
        fragmented.extend([22, 3, 3]);
        fragmented.extend(((payload.len() - split) as u16).to_be_bytes());
        fragmented.extend(&payload[split..]);
        assert_eq!(
            parse_sni(&fragmented).unwrap().as_deref(),
            Some("gs-loc.apple.com")
        );
    }

    #[test]
    fn rejects_incomplete_and_invalid_names() {
        let hello = client_hello(Some("bad_host"));
        assert!(matches!(parse_sni(&hello), Err(HelloError::Malformed)));
        let valid = client_hello(None);
        assert_eq!(parse_sni(&valid).unwrap(), None);
        assert!(matches!(
            parse_sni(&valid[..valid.len() - 1]),
            Err(HelloError::Incomplete)
        ));
    }
}
