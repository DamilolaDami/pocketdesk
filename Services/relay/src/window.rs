//! A fixed congestion window for the relay's connections to devices.
//!
//! Nearly everything the relay sends is another QUIC session's packets, and that session
//! already controls its rate end to end. A second controller on the relay's own leg read each
//! lost packet as congestion: with a couple of percent loss on the way to a phone, Cubic held
//! the leg near half a megabit and the datagrams waiting behind it added seconds of delay,
//! which the inner session then read as congestion too. The window here never shrinks; the
//! per-connection budget in `relay.rs` still bounds what any device can make the relay send.

use quinn::congestion::{Controller, ControllerFactory};
use std::{any::Any, sync::Arc, time::Instant};

/// Enough for the budget's 2 MiB/s over a 250 ms round trip.
pub const WINDOW: u64 = 512 * 1024;

#[derive(Debug, Clone, Copy, Default)]
pub struct Fixed;

impl ControllerFactory for Fixed {
    fn build(self: Arc<Self>, _now: Instant, _mtu: u16) -> Box<dyn Controller> {
        Box::new(Fixed)
    }
}

impl Controller for Fixed {
    fn on_congestion_event(&mut self, _: Instant, _: Instant, _: bool, _: u64) {}
    fn on_mtu_update(&mut self, _: u16) {}
    fn window(&self) -> u64 {
        WINDOW
    }
    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(*self)
    }
    fn initial_window(&self) -> u64 {
        WINDOW
    }
    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}
