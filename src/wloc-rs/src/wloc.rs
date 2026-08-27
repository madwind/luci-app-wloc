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

#[cfg(test)]
fn patch_location(
    payload: &[u8],
    target: PatchTarget,
) -> Result<Option<PatchedLocation>, WlocError> {
    patch_location_with(payload, &mut |_| target)
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

#[cfg(test)]
fn patch_response(body: &[u8], target: PatchTarget) -> Result<PatchedResponse, WlocError> {
    patch_response_with(body, &mut |_| target)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn field(number: u32, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        message_field(number, payload, &mut out);
        out
    }
    fn fixture_at(latitude_e8: i64, longitude_e8: i64, accuracy: i64) -> Vec<u8> {
        fixture_many(&[(latitude_e8, longitude_e8, accuracy)])
    }

    fn fixture_many(locations: &[(i64, i64, i64)]) -> Vec<u8> {
        let mut wifi = field(1, b"aa:bb:cc:dd:ee:ff");
        for &(latitude_e8, longitude_e8, accuracy) in locations {
            let location = {
                let mut v = Vec::new();
                varint_field(1, latitude_e8, &mut v);
                varint_field(2, longitude_e8, &mut v);
                varint_field(3, accuracy, &mut v);
                varint_field(9, 77, &mut v);
                v
            };
            wifi.extend(field(2, &location));
        }
        let payload = field(2, &wifi);
        let mut body = vec![0, 1, 0, 0, 0, 1];
        body.extend((payload.len() as u32).to_be_bytes());
        body.extend(payload);
        body
    }

    fn fixture() -> Vec<u8> {
        fixture_at(1, 2, 9)
    }

    fn parse_varint_fields(bytes: &[u8]) -> Vec<(u32, i64)> {
        fields(bytes)
            .unwrap()
            .into_iter()
            .filter(|field| field.wire == 0)
            .map(|field| {
                let (value, _) = decode_varint(field.value, 0).unwrap();
                (field.number, value as i64)
            })
            .collect()
    }

    #[test]
    fn follows_every_location_in_one_response_in_protobuf_order() {
        let response = fixture_many(&[
            (coordinate(80.0), coordinate(90.0), 37),
            (coordinate(70.0), coordinate(100.0), 20),
            (coordinate(72.0), coordinate(97.0), 21),
            (coordinate(71.5), coordinate(98.25), 23),
        ]);
        let mut follower = LocationFollower::new(PatchTarget::new(50.0, 20.0).unwrap());

        let (patched, last_target) = patch_response_following(&response, &mut follower).unwrap();

        assert_eq!(patched.locations, 4);
        assert_eq!(
            patched
                .changes
                .iter()
                .map(|change| (
                    change.latitude_after_e8,
                    change.longitude_after_e8,
                    change.accuracy_after,
                ))
                .collect::<Vec<_>>(),
            vec![
                (coordinate(50.0), coordinate(20.0), Some(37)),
                (coordinate(40.0), coordinate(30.0), Some(20)),
                (coordinate(52.0), coordinate(17.0), Some(21)),
                (coordinate(49.5), coordinate(21.25), Some(23)),
            ]
        );
        assert_eq!(last_target, PatchTarget::new(49.5, 21.25).unwrap());
    }

    #[test]
    fn validates_and_patches_only_wloc_envelopes() {
        let body = fixture();
        assert!(valid_request(&body));
        let out = patch_response(&body, PatchTarget::new(22.3, 114.2).unwrap()).unwrap();
        assert_ne!(out.body, body);
        assert_eq!(
            u32::from_be_bytes(out.body[6..10].try_into().unwrap()) as usize,
            out.body.len() - 10
        );
        assert_eq!(out.wifi_devices, 1);
        assert_eq!(out.locations, 1);
        assert_eq!(out.changes[0].source, "wifi");
        assert!(patch_response(b"not protobuf", PatchTarget::new(0.0, 0.0).unwrap()).is_err());
    }

    #[test]
    fn replaces_only_existing_coordinates_and_preserves_accuracy() {
        let mut old = Vec::new();
        for number in [1, 2, 3, 4, 5, 6, 11, 12] {
            varint_field(number, 9_999, &mut old);
        }
        varint_field(9, 77, &mut old);
        let patched = patch_location(&old, PatchTarget::new(22.3, 114.2).unwrap())
            .unwrap()
            .unwrap();
        let patched = patched.body;
        let values = parse_varint_fields(&patched);
        assert_eq!(values.iter().filter(|(n, _)| *n == 9).count(), 1);
        assert!(values.contains(&(1, 2_230_000_000)));
        assert!(values.contains(&(2, 11_420_000_000)));
        assert!(values.contains(&(3, 9_999)));
        for number in [4, 5, 6, 11, 12] {
            assert!(values.contains(&(number, 9_999)));
        }
    }

    #[test]
    fn preserves_all_root_fields() {
        let body = fixture();
        let env = envelope(&body).unwrap();
        let mut payload = env.payload().to_vec();
        for number in [3, 4, 33] {
            varint_field(number, 123, &mut payload);
        }
        let mut wrapped = vec![0, 1, 0, 0, 0, 1];
        wrapped.extend((payload.len() as u32).to_be_bytes());
        wrapped.extend(payload);
        let out = patch_response(&wrapped, PatchTarget::new(1.0, 2.0).unwrap()).unwrap();
        let patched = envelope(&out.body).unwrap();
        let root = fields(patched.payload()).unwrap();
        for number in [3, 4, 33] {
            assert!(root.iter().any(|field| field.number == number));
        }
    }

    #[test]
    fn does_not_invent_a_missing_location() {
        let wifi = field(1, b"aa:bb:cc:dd:ee:ff");
        let payload = field(2, &wifi);
        let mut body = vec![0, 1, 0, 0, 0, 1];
        body.extend((payload.len() as u32).to_be_bytes());
        body.extend(payload);
        assert_eq!(
            patch_response(&body, PatchTarget::new(1.0, 2.0).unwrap()),
            Err(WlocError::NotWloc)
        );
    }

    #[test]
    fn does_not_patch_a_wifi_message_without_a_bssid() {
        let mut location = Vec::new();
        varint_field(1, 1, &mut location);
        varint_field(2, 2, &mut location);
        let wifi = field(2, &location);
        let payload = field(2, &wifi);
        let mut body = vec![0, 1, 0, 0, 0, 1];
        body.extend((payload.len() as u32).to_be_bytes());
        body.extend(payload);
        assert_eq!(
            patch_response(&body, PatchTarget::new(1.0, 2.0).unwrap()),
            Err(WlocError::NotWloc)
        );
    }

    #[test]
    fn invalid_coordinates_are_rejected() {
        assert_eq!(
            PatchTarget::new(91.0, 0.0),
            Err(WlocError::InvalidCoordinates)
        );
        assert_eq!(
            PatchTarget::new(0.0, 181.0),
            Err(WlocError::InvalidCoordinates)
        );
        assert_eq!(
            PatchTarget::new(f64::NAN, 0.0),
            Err(WlocError::InvalidCoordinates)
        );
    }

    #[test]
    fn unrelated_protobuf_is_not_patched() {
        let mut payload = Vec::new();
        varint_field(8, 1, &mut payload);
        let mut body = vec![0, 1, 0, 0, 0, 1];
        body.extend((payload.len() as u32).to_be_bytes());
        body.extend(payload);
        assert!(!valid_request(&body));
        assert_eq!(
            patch_response(&body, PatchTarget::new(1.0, 2.0).unwrap()),
            Err(WlocError::NotWloc)
        );
    }

    #[test]
    fn follows_only_the_latest_real_delta_from_the_fixed_virtual_baseline() {
        let mut follower = LocationFollower::new(PatchTarget::new(50.0, 20.0).unwrap());

        let (first, first_target) = patch_response_following(
            &fixture_at(coordinate(80.0), coordinate(90.0), 15),
            &mut follower,
        )
        .unwrap();
        assert_eq!(first_target, PatchTarget::new(50.0, 20.0).unwrap());
        assert_eq!(first.changes[0].accuracy_before, Some(15));
        assert_eq!(first.changes[0].accuracy_after, Some(15));

        let (second, second_target) = patch_response_following(
            &fixture_at(coordinate(70.0), coordinate(100.0), 27),
            &mut follower,
        )
        .unwrap();
        assert_eq!(second_target, PatchTarget::new(40.0, 30.0).unwrap());
        assert_eq!(second.changes[0].accuracy_before, Some(27));
        assert_eq!(second.changes[0].accuracy_after, Some(27));

        let (_, third_target) = patch_response_following(
            &fixture_at(coordinate(72.0), coordinate(97.0), 8),
            &mut follower,
        )
        .unwrap();
        assert_eq!(third_target, PatchTarget::new(52.0, 17.0).unwrap());
    }

    #[test]
    fn a_new_follower_uses_the_first_real_location_only_as_its_reference() {
        let response = fixture_at(coordinate(72.0), coordinate(97.0), 8);
        let mut restarted = LocationFollower::new(PatchTarget::new(50.0, 20.0).unwrap());
        let (_, target) = patch_response_following(&response, &mut restarted).unwrap();
        assert_eq!(target, PatchTarget::new(50.0, 20.0).unwrap());
    }

    #[test]
    fn followed_coordinates_stay_in_valid_wgs84_ranges() {
        let mut follower = LocationFollower::new(PatchTarget::new(89.0, 179.0).unwrap());
        assert_eq!(
            follower.follow((0, 0)),
            PatchTarget::new(89.0, 179.0).unwrap()
        );
        assert_eq!(
            follower.follow((coordinate(2.0), coordinate(3.0))),
            PatchTarget::new(90.0, -178.0).unwrap()
        );
    }

    #[test]
    fn malformed_inputs_never_panic() {
        let target = PatchTarget::new(1.0, 2.0).unwrap();
        let mut state = 0x9e37_79b9_u32;
        for length in 0..2048_usize {
            let mut input = Vec::with_capacity(length);
            for _ in 0..length {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                input.push(state as u8);
            }
            let _ = valid_request(&input);
            let _ = request_kind(&input);
            let _ = request_wifi_devices(&input);
            let _ = patch_response(&input, target);
        }
    }
}
