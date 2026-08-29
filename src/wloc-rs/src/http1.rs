use http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Uri};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::proxy::{ProxyError, UpstreamResponse};

const MAX_RESPONSE: usize = 512 * 1024;
const MAX_HEADERS: usize = 64 * 1024;
const MAX_WIRE_RESPONSE: usize = MAX_RESPONSE + MAX_HEADERS;

pub async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    hostname: &str,
    body: &[u8],
) -> Result<UpstreamResponse, ProxyError> {
    let path = uri.path_and_query().map(|v| v.as_str()).unwrap_or("/");
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: {hostname}\r\nConnection: close\r\nAccept-Encoding: identity\r\n").into_bytes();
    for (name, value) in headers {
        let name = name.as_str().to_ascii_lowercase();
        if [
            "host",
            "connection",
            "proxy-connection",
            "keep-alive",
            "transfer-encoding",
            "upgrade",
            "te",
            "content-length",
            "accept-encoding",
        ]
        .contains(&name.as_str())
        {
            continue;
        }
        if let Ok(value) = value.to_str() {
            request.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
        }
    }
    if !body.is_empty() {
        request.extend_from_slice(format!("Content-Length: {}\r\n", body.len()).as_bytes());
    }
    request.extend_from_slice(b"\r\n");
    stream.write_all(&request).await.map_err(ProxyError::io)?;
    if !body.is_empty() {
        stream.write_all(body).await.map_err(ProxyError::io)?;
    }

    let mut raw = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        let count = stream.read(&mut chunk).await.map_err(ProxyError::io)?;
        if count == 0 {
            break;
        }
        raw.extend_from_slice(&chunk[..count]);
        if raw.len() > MAX_WIRE_RESPONSE {
            return Err(ProxyError::Upstream("HTTP/1 response exceeds bound".into()));
        }
    }
    parse(&raw)
}

fn parse(raw: &[u8]) -> Result<UpstreamResponse, ProxyError> {
    let header_end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| ProxyError::Upstream("malformed HTTP/1 response".into()))?;
    if header_end > MAX_HEADERS {
        return Err(ProxyError::Upstream("HTTP/1 headers exceed bound".into()));
    }
    let text = std::str::from_utf8(&raw[..header_end])
        .map_err(|_| ProxyError::Upstream("non-UTF8 HTTP/1 headers".into()))?;
    let mut lines = text.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .and_then(|s| StatusCode::from_u16(s).ok())
        .ok_or_else(|| ProxyError::Upstream("invalid HTTP/1 status".into()))?;
    let mut headers = HeaderMap::new();
    let mut content_length = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let lower = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if lower == "content-length" {
            let parsed = value
                .parse::<usize>()
                .map_err(|_| ProxyError::Upstream("invalid HTTP/1 content length".into()))?;
            if content_length.is_some_and(|existing| existing != parsed) {
                return Err(ProxyError::Upstream(
                    "conflicting HTTP/1 content lengths".into(),
                ));
            }
            content_length = Some(parsed);
        }
        if lower == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked") {
            chunked = true;
        }
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(lower.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            headers.append(name, value);
        }
    }
    if chunked && content_length.is_some() {
        return Err(ProxyError::Upstream(
            "ambiguous HTTP/1 message framing".into(),
        ));
    }
    let wire_body = &raw[header_end + 4..];
    let body = if chunked {
        decode_chunked(wire_body)?
    } else if let Some(len) = content_length {
        if len > MAX_RESPONSE {
            return Err(ProxyError::Upstream("HTTP/1 body exceeds bound".into()));
        }
        if len > wire_body.len() {
            return Err(ProxyError::Upstream("truncated HTTP/1 body".into()));
        }
        wire_body[..len].to_vec()
    } else {
        wire_body.to_vec()
    };
    Ok(UpstreamResponse {
        status,
        headers,
        body,
        wloc: false,
        response_mode: "forwarded",
        request_kind: None,
        patched_target: None,
    })
}

fn decode_chunked(mut input: &[u8]) -> Result<Vec<u8>, ProxyError> {
    let mut out = Vec::new();
    loop {
        let line_end = input
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or_else(|| ProxyError::Upstream("invalid chunk header".into()))?;
        let size_text = std::str::from_utf8(&input[..line_end])
            .map_err(|_| ProxyError::Upstream("invalid chunk size".into()))?
            .split(';')
            .next()
            .unwrap_or("");
        let size = usize::from_str_radix(size_text.trim(), 16)
            .map_err(|_| ProxyError::Upstream("invalid chunk size".into()))?;
        input = &input[line_end + 2..];
        if size == 0 {
            break;
        }
        if size > input.len() || size > MAX_RESPONSE.saturating_sub(out.len()) {
            return Err(ProxyError::Upstream("invalid chunk length".into()));
        }
        out.extend_from_slice(&input[..size]);
        if input.get(size..size + 2) != Some(b"\r\n") {
            return Err(ProxyError::Upstream("invalid chunk terminator".into()));
        }
        input = input
            .get(size + 2..)
            .ok_or_else(|| ProxyError::Upstream("truncated chunk".into()))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_content_length_and_chunked_responses() {
        let plain =
            parse(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello").unwrap();
        assert_eq!(plain.status, StatusCode::OK);
        assert_eq!(plain.body, b"hello");

        let chunked = parse(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n",
        )
        .unwrap();
        assert_eq!(chunked.body, b"abcde");
    }

    #[test]
    fn rejects_ambiguous_or_malformed_framing() {
        assert!(
            parse(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na").is_err()
        );
        assert!(parse(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n"
        )
        .is_err());
        assert!(decode_chunked(b"1\r\naXX0\r\n\r\n").is_err());
        assert!(parse(b"HTTP/1.1 200 OK\r\nContent-Length: 524289\r\n\r\n").is_err());
    }
}
