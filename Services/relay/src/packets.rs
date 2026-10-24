//! The inner QUIC Initial is at least 1200 bytes. Fragment the opaque UDP packet so
//! nesting it in a QUIC DATAGRAM never requires raising the outer path's minimum MTU.
use crate::protocol::MAX_PACKET;
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use uuid::Uuid;
const CHUNK: usize = 1000;
pub fn encode(session: Uuid, payload: &[u8]) -> Vec<Vec<u8>> {
    if payload.is_empty() || payload.len() > MAX_PACKET {
        return vec![];
    }
    let packet = Uuid::new_v4();
    let count = payload.len().div_ceil(CHUNK) as u8;
    payload
        .chunks(CHUNK)
        .enumerate()
        .map(|(i, chunk)| {
            let mut bytes = Vec::with_capacity(34 + chunk.len());
            bytes.extend_from_slice(session.as_bytes());
            bytes.extend_from_slice(packet.as_bytes());
            bytes.extend_from_slice(&[i as u8, count]);
            bytes.extend_from_slice(chunk);
            bytes
        })
        .collect()
}
struct Pending {
    packet: Uuid,
    first: Option<Vec<u8>>,
    second: Option<Vec<u8>>,
    start: Instant,
}
#[derive(Default)]
pub struct Assembler {
    pending: HashMap<Uuid, Pending>,
}
impl Assembler {
    pub fn push(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        if bytes.len() <= 34 || bytes.len() > 1034 {
            return None;
        }
        let session = Uuid::from_slice(&bytes[..16]).ok()?;
        let packet = Uuid::from_slice(&bytes[16..32]).ok()?;
        let (index, count) = (bytes[32], bytes[33]);
        if count == 1 && index == 0 {
            return Some(bytes[34..].to_vec());
        }
        if count != 2
            || index > 1
            || (index == 0 && bytes.len() != 1034)
            || (index == 1 && bytes.len() > MAX_PACKET - CHUNK + 34)
        {
            return None;
        }
        self.pending
            .retain(|_, p| p.start.elapsed() < Duration::from_secs(1));
        if !self.pending.contains_key(&session) && self.pending.len() >= 2 {
            return None;
        }
        let p = self.pending.entry(session).or_insert_with(|| Pending {
            packet,
            first: None,
            second: None,
            start: Instant::now(),
        });
        if p.packet != packet {
            *p = Pending {
                packet,
                first: None,
                second: None,
                start: Instant::now(),
            };
        }
        if index == 0 {
            p.first = Some(bytes[34..].to_vec());
        } else {
            p.second = Some(bytes[34..].to_vec());
        }
        if p.first.is_some() && p.second.is_some() {
            let mut p = self.pending.remove(&session)?;
            let mut result = p.first.take()?;
            result.extend(p.second.take()?);
            Some(result)
        } else {
            None
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inner_initial_survives_out_of_order_fragments() {
        let payload = vec![91; 1200];
        let packets = encode(Uuid::new_v4(), &payload);
        let mut a = Assembler::default();
        assert!(a.push(&packets[1]).is_none());
        assert_eq!(a.push(&packets[0]), Some(payload));
        assert!(a.push(&[0; 1500]).is_none());
    }
}
