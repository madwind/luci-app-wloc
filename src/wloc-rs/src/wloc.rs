//! Bounded Apple WLOC protobuf transformer.
//!
//! Protocol facts and the original clean-room implementation were audited
//! from smthdagg/wificalling-location-gateway (MIT). This implementation is
//! deliberately narrower: it only normalizes the documented Location fields
//! in already-recognized messages and preserves all unrelated protobuf bytes.

use std::fmt;

const MAX_BODY: usize = 512 * 1024;
const CELL_FIELDS: [u32; 2] = [22, 24];
const COORDINATE_SCALE: f64 = 100_000_000.0;
const LATITUDE_MAX_E8: i64 = 90 * 100_000_000;
const LONGITUDE_MAX_E8: i64 = 180 * 100_000_000;
const LONGITUDE_SPAN_E8: i64 = 360 * 100_000_000;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PatchTarget {
    pub latitude: f64,
    pub longitude: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LocationFollower {
    base_virtual_e8: (i64, i64),
    last_real_e8: Option<(i64, i64)>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PatchedResponse {
    pub body: Vec<u8>,
    pub wifi_devices: u32,
    pub cell_responses: u32,
    pub locations: u32,
    pub skipped_locations: u32,
    pub changes: Vec<LocationChange>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocationChange {
    pub source: &'static str,
    pub latitude_before_e8: i64,
    pub longitude_before_e8: i64,
    pub accuracy_before: Option<u64>,
    pub latitude_after_e8: i64,
    pub longitude_after_e8: i64,
    pub accuracy_after: Option<u64>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct PatchStats {
    wifi_devices: u32,
    cell_responses: u32,
    locations: u32,
    skipped_locations: u32,
    changes: Vec<LocationChange>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PatchedLocation {
    body: Vec<u8>,
    latitude_before_e8: i64,
    longitude_before_e8: i64,
    accuracy_before: Option<u64>,
    latitude_after_e8: i64,
    longitude_after_e8: i64,
    accuracy_after: Option<u64>,
}

impl PatchTarget {
    pub fn new(latitude: f64, longitude: f64) -> Result<Self, WlocError> {
        if !latitude.is_finite()
            || !longitude.is_finite()
            || !(-90.0..=90.0).contains(&latitude)
            || !(-180.0..=180.0).contains(&longitude)
        {
            return Err(WlocError::InvalidCoordinates);
        }
        Ok(Self {
            latitude,
            longitude,
        })
    }
}

impl LocationFollower {
    pub fn new(initial: PatchTarget) -> Self {
        Self {
            base_virtual_e8: (coordinate(initial.latitude), coordinate(initial.longitude)),
            last_real_e8: None,
        }
    }

    fn follow(&mut self, real_e8: (i64, i64)) -> PatchTarget {
        let virtual_e8 = if let Some(previous_real_e8) = self.last_real_e8 {
            let latitude_delta = real_e8.0.saturating_sub(previous_real_e8.0);
            let longitude_delta = shortest_longitude_delta(real_e8.1, previous_real_e8.1);
            (
                self.base_virtual_e8
                    .0
                    .saturating_add(latitude_delta)
                    .clamp(-LATITUDE_MAX_E8, LATITUDE_MAX_E8),
                normalize_longitude_e8(self.base_virtual_e8.1.saturating_add(longitude_delta)),
            )
        } else {
            self.base_virtual_e8
        };
        self.last_real_e8 = Some(real_e8);
        PatchTarget {
            latitude: virtual_e8.0 as f64 / COORDINATE_SCALE,
            longitude: virtual_e8.1 as f64 / COORDINATE_SCALE,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WlocError {
    Oversized,
    Truncated,
    UnsupportedWireType(u8),
    InvalidField,
    InvalidEnvelope,
    InvalidCoordinates,
    NotWloc,
}

impl fmt::Display for WlocError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for WlocError {}

#[derive(Debug)]
struct Field<'a> {
    number: u32,
    wire: u8,
    raw: &'a [u8],
    value: &'a [u8],
}

fn decode_varint(bytes: &[u8], start: usize) -> Result<(u64, usize), WlocError> {
    let mut value = 0_u64;
    for shift in 0..10 {
        let pos = start.checked_add(shift).ok_or(WlocError::Truncated)?;
        let byte = *bytes.get(pos).ok_or(WlocError::Truncated)?;
        if shift == 9 && byte > 1 {
            return Err(WlocError::Truncated);
        }
        value |= u64::from(byte & 0x7f) << (shift * 7);
        if byte & 0x80 == 0 {
            return Ok((value, pos + 1));
        }
    }
    Err(WlocError::Truncated)
}

fn fields(bytes: &[u8]) -> Result<Vec<Field<'_>>, WlocError> {
    if bytes.len() > MAX_BODY {
        return Err(WlocError::Oversized);
    }
    let mut out = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        let begin = offset;
        let (key, key_end) = decode_varint(bytes, offset)?;
        let number = (key >> 3) as u32;
        let wire = (key & 7) as u8;
        if number == 0 {
            return Err(WlocError::InvalidField);
        }
        let (value_start, end) = match wire {
            0 => {
                let (_, end) = decode_varint(bytes, key_end)?;
                (key_end, end)
            }
            1 => (key_end, key_end.checked_add(8).ok_or(WlocError::Truncated)?),
            2 => {
                let (len, data) = decode_varint(bytes, key_end)?;
                let len = usize::try_from(len).map_err(|_| WlocError::Truncated)?;
                (data, data.checked_add(len).ok_or(WlocError::Truncated)?)
            }
            5 => (key_end, key_end.checked_add(4).ok_or(WlocError::Truncated)?),
            other => return Err(WlocError::UnsupportedWireType(other)),
        };
        if end > bytes.len() {
            return Err(WlocError::Truncated);
        }
        out.push(Field {
            number,
            wire,
            raw: &bytes[begin..end],
            value: &bytes[value_start..end],
        });
        offset = end;
    }
    Ok(out)
}

fn put_varint(mut value: u64, out: &mut Vec<u8>) {
    while value >= 0x80 {
        out.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

fn varint_field(number: u32, value: i64, out: &mut Vec<u8>) {
    put_varint(u64::from(number) << 3, out);
    put_varint(value as u64, out);
}

fn message_field(number: u32, message: &[u8], out: &mut Vec<u8>) {
    put_varint((u64::from(number) << 3) | 2, out);
    put_varint(message.len() as u64, out);
    out.extend_from_slice(message);
}

fn coordinate(value: f64) -> i64 {
    (value * COORDINATE_SCALE).round() as i64
}

fn normalize_longitude_e8(value: i64) -> i64 {
    if (-LONGITUDE_MAX_E8..=LONGITUDE_MAX_E8).contains(&value) {
        return value;
    }
    (value + LONGITUDE_MAX_E8).rem_euclid(LONGITUDE_SPAN_E8) - LONGITUDE_MAX_E8
}

fn shortest_longitude_delta(current: i64, previous: i64) -> i64 {
    let delta = current.saturating_sub(previous);
    if delta > LONGITUDE_MAX_E8 {
        delta - LONGITUDE_SPAN_E8
    } else if delta < -LONGITUDE_MAX_E8 {
        delta + LONGITUDE_SPAN_E8
    } else {
        delta
    }
}

fn patch_location_with<F>(
    payload: &[u8],
    target_for: &mut F,
) -> Result<Option<PatchedLocation>, WlocError>
where
    F: FnMut((i64, i64)) -> PatchTarget,
{
    let parsed = fields(payload)?;
    let latitude_before_e8 = parsed
        .iter()
        .find(|field| field.number == 1 && field.wire == 0)
        .and_then(|field| decode_varint(field.value, 0).ok())
        .map(|(value, _)| value as i64);
    let longitude_before_e8 = parsed
        .iter()
        .find(|field| field.number == 2 && field.wire == 0)
        .and_then(|field| decode_varint(field.value, 0).ok())
        .map(|(value, _)| value as i64);
    let (Some(latitude_before_e8), Some(longitude_before_e8)) =
        (latitude_before_e8, longitude_before_e8)
    else {
        return Ok(None);
    };
    let accuracy_before = parsed
        .iter()
        .find(|field| field.number == 3 && field.wire == 0)
        .and_then(|field| decode_varint(field.value, 0).ok())
        .map(|(value, _)| value);
    let target = target_for((latitude_before_e8, longitude_before_e8));
    let latitude_after_e8 = coordinate(target.latitude);
    let longitude_after_e8 = coordinate(target.longitude);
    let accuracy_after = accuracy_before;
    let mut out = Vec::with_capacity(payload.len() + 32);
    for field in parsed {
        match (field.number, field.wire) {
            (1, 0) => varint_field(1, latitude_after_e8, &mut out),
            (2, 0) => varint_field(2, longitude_after_e8, &mut out),
            _ => out.extend_from_slice(field.raw),
        }
    }
    Ok(Some(PatchedLocation {
        body: out,
        latitude_before_e8,
        longitude_before_e8,
        accuracy_before,
        latitude_after_e8,
        longitude_after_e8,
        accuracy_after,
    }))
}

fn record_location(stats: &mut PatchStats, source: &'static str, location: &PatchedLocation) {
    stats.locations += 1;
    stats.changes.push(LocationChange {
        source,
        latitude_before_e8: location.latitude_before_e8,
        longitude_before_e8: location.longitude_before_e8,
        accuracy_before: location.accuracy_before,
        latitude_after_e8: location.latitude_after_e8,
        longitude_after_e8: location.longitude_after_e8,
        accuracy_after: location.accuracy_after,
    });
}

fn valid_bssid(value: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(value) else {
        return false;
    };
    let mut count = 0;
    for part in text.split(':') {
        if part.is_empty() || part.len() > 2 || !part.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return false;
        }
        count += 1;
    }
    count == 6
}

fn patch_wifi_device<F>(
    payload: &[u8],
    target_for: &mut F,
    stats: &mut PatchStats,
) -> Result<Vec<u8>, WlocError>
where
    F: FnMut((i64, i64)) -> PatchTarget,
{
    let parsed = fields(payload)?;
    if !parsed
        .iter()
        .any(|field| field.number == 1 && field.wire == 2 && valid_bssid(field.value))
    {
        return Ok(payload.to_vec());
    }
    let mut out = Vec::with_capacity(payload.len() + 32);
    let mut changed = false;
    for field in parsed {
        if field.number == 2 && field.wire == 2 {
            match patch_location_with(field.value, target_for) {
                Ok(Some(location)) => {
                    changed |= location.body != field.value;
                    message_field(2, &location.body, &mut out);
                    record_location(stats, "wifi", &location);
                }
                Ok(None) => out.extend_from_slice(field.raw),
                Err(_) => {
                    stats.skipped_locations += 1;
                    out.extend_from_slice(field.raw);
                }
            }
        } else {
            out.extend_from_slice(field.raw);
        }
    }
    if changed {
        stats.wifi_devices += 1;
    }
    Ok(out)
}

fn patch_cell_response<F>(
    payload: &[u8],
    target_for: &mut F,
    stats: &mut PatchStats,
) -> Result<Vec<u8>, WlocError>
where
    F: FnMut((i64, i64)) -> PatchTarget,
{
    let parsed = fields(payload)?;
    let mut out = Vec::with_capacity(payload.len() + 32);
    let mut changed = false;
    for field in parsed {
        if field.number == 5 && field.wire == 2 {
            match patch_location_with(field.value, target_for) {
                Ok(Some(location)) => {
                    changed |= location.body != field.value;
                    message_field(5, &location.body, &mut out);
                    record_location(stats, "cell", &location);
                }
                Ok(None) => out.extend_from_slice(field.raw),
                Err(_) => {
                    stats.skipped_locations += 1;
                    out.extend_from_slice(field.raw);
                }
            }
        } else {
            out.extend_from_slice(field.raw);
        }
    }
    if changed {
        stats.cell_responses += 1;
    }
    Ok(out)
}

fn patch_payload<F>(
    payload: &[u8],
    target_for: &mut F,
    stats: &mut PatchStats,
) -> Result<Vec<u8>, WlocError>
where
    F: FnMut((i64, i64)) -> PatchTarget,
{
    let parsed = fields(payload)?;
    let mut out = Vec::with_capacity(payload.len() + 64);
    for field in parsed {
        match (field.number, field.wire) {
            (2, 2) => {
                message_field(
                    2,
                    &patch_wifi_device(field.value, target_for, stats)?,
                    &mut out,
                );
            }
            (n, 2) if CELL_FIELDS.contains(&n) => {
                message_field(
                    n,
                    &patch_cell_response(field.value, target_for, stats)?,
                    &mut out,
                );
            }
            _ => out.extend_from_slice(field.raw),
        }
    }
    if stats.locations == 0 {
        return Err(WlocError::NotWloc);
    }
    Ok(out)
}

enum Envelope<'a> {
    Wloc10 {
        header: &'a [u8],
        payload: &'a [u8],
        suffix: &'a [u8],
    },
    Marker {
        pre: &'a [u8],
        kind: u8,
        payload: &'a [u8],
        suffix: &'a [u8],
    },
}

impl<'a> Envelope<'a> {
    fn payload(&self) -> &'a [u8] {
        match self {
            Self::Wloc10 { payload, .. } | Self::Marker { payload, .. } => payload,
        }
    }
    fn kind(&self) -> u8 {
        match self {
            Self::Wloc10 { header, .. } => header[5],
            Self::Marker { kind, .. } => *kind,
        }
    }
}

fn envelope(body: &[u8]) -> Result<Envelope<'_>, WlocError> {
    if body.len() > MAX_BODY + 128 {
        return Err(WlocError::Oversized);
    }
    if body.len() >= 10 && body[0..2] == [0, 1] {
        let len = u32::from_be_bytes(body[6..10].try_into().unwrap()) as usize;
        if len > 0
            && 10_usize
                .checked_add(len)
                .is_some_and(|end| end <= body.len())
        {
            let end = 10 + len;
            if fields(&body[10..end]).is_ok() {
                return Ok(Envelope::Wloc10 {
                    header: &body[..10],
                    payload: &body[10..end],
                    suffix: &body[end..],
                });
            }
        }
    }
    for index in 0..body.len().saturating_sub(7) {
        if index + 8 > body.len() {
            break;
        }
        if body[index] == 0
            && body[index + 1] == 0
            && body[index + 2] == 0
            && body[index + 4] == 0
            && body[index + 5] == 0
        {
            let kind = body[index + 3];
            let len = u16::from_be_bytes([body[index + 6], body[index + 7]]) as usize;
            let start = index + 8;
            if len > 0 && start.checked_add(len).is_some_and(|end| end <= body.len()) {
                let end = start + len;
                if fields(&body[start..end]).is_ok() {
                    return Ok(Envelope::Marker {
                        pre: &body[..index],
                        kind,
                        payload: &body[start..end],
                        suffix: &body[end..],
                    });
                }
            }
        }
    }
    Err(WlocError::InvalidEnvelope)
}

pub fn valid_request(body: &[u8]) -> bool {
    let Ok(env) = envelope(body) else {
        return false;
    };
    if env.kind() == 3 {
        return fields(env.payload()).is_ok();
    }
    fields(env.payload()).is_ok_and(|items| items.iter().any(|f| f.number == 2 && f.wire == 2))
}

pub fn request_kind(body: &[u8]) -> Option<u8> {
    envelope(body).ok().map(|envelope| envelope.kind())
}

pub fn request_wifi_devices(body: &[u8]) -> Option<usize> {
    let envelope = envelope(body).ok()?;
    let parsed = fields(envelope.payload()).ok()?;
    Some(
        parsed
            .iter()
            .filter(|field| field.number == 2 && field.wire == 2)
            .count(),
    )
}

fn patch_response_with<F>(body: &[u8], target_for: &mut F) -> Result<PatchedResponse, WlocError>
where
    F: FnMut((i64, i64)) -> PatchTarget,
{
    let env = envelope(body)?;
    let mut stats = PatchStats::default();
    let payload = patch_payload(env.payload(), target_for, &mut stats)?;
    let body = match env {
        Envelope::Wloc10 { header, suffix, .. } => {
            let len = u32::try_from(payload.len()).map_err(|_| WlocError::Oversized)?;
            let mut out = header.to_vec();
            out[6..10].copy_from_slice(&len.to_be_bytes());
            out.extend_from_slice(&payload);
            out.extend_from_slice(suffix);
            out
        }
        Envelope::Marker {
            pre, kind, suffix, ..
        } => {
            let len = u16::try_from(payload.len()).map_err(|_| WlocError::Oversized)?;
            let mut out = pre.to_vec();
            out.extend([0, 0, 0, kind, 0, 0]);
            out.extend(len.to_be_bytes());
            out.extend_from_slice(&payload);
            out.extend_from_slice(suffix);
            out
        }
    };
    if body.len() > MAX_BODY {
        return Err(WlocError::Oversized);
    }
    Ok(PatchedResponse {
        body,
        wifi_devices: stats.wifi_devices,
        cell_responses: stats.cell_responses,
        locations: stats.locations,
        skipped_locations: stats.skipped_locations,
        changes: stats.changes,
    })
}

pub fn patch_response_following(
    body: &[u8],
    follower: &mut LocationFollower,
) -> Result<(PatchedResponse, PatchTarget), WlocError> {
    let mut next = *follower;
    let mut last_target = None;
    let patched = patch_response_with(body, &mut |real_e8| {
        let target = next.follow(real_e8);
        last_target = Some(target);
        target
    })?;
    let target = last_target.ok_or(WlocError::NotWloc)?;
    *follower = next;
    Ok((patched, target))
}
