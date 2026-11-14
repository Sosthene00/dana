use std::sync::Mutex;

use crate::api::structs::frigate_event::FrigateEventDto;
use crate::api::structs::state_update::StateUpdate;
use crate::frb_generated::StreamSink;

use lazy_static::lazy_static;

lazy_static! {
    static ref SCAN_PROGRESS_STREAM_SINK: Mutex<Option<StreamSink<u32>>> = Mutex::new(None);
    static ref STATE_UPDATE_STREAM_SINK: Mutex<Option<StreamSink<StateUpdate>>> = Mutex::new(None);
    static ref TX_BROADCAST_STREAM_SINK: Mutex<Option<StreamSink<String>>> = Mutex::new(None);
    static ref FRIGATE_EVENT_STREAM_SINK: Mutex<Option<StreamSink<FrigateEventDto>>> =
        Mutex::new(None);
}

pub fn create_sync_progress_stream(s: StreamSink<u32>) {
    let mut stream_sink = SCAN_PROGRESS_STREAM_SINK.lock().unwrap();
    *stream_sink = Some(s);
}

pub fn create_sync_update_stream(s: StreamSink<StateUpdate>) {
    let mut stream_sink = STATE_UPDATE_STREAM_SINK.lock().unwrap();
    *stream_sink = Some(s);
}

pub fn create_tx_broadcast_stream(s: StreamSink<String>) {
    let mut stream_sink = TX_BROADCAST_STREAM_SINK.lock().unwrap();
    *stream_sink = Some(s);
}

pub(crate) fn send_sync_progress(scan_progress: u32) {
    let stream_sink = SCAN_PROGRESS_STREAM_SINK.lock().unwrap();
    if let Some(stream_sink) = stream_sink.as_ref() {
        // Silently ignore send errors: the main isolate may have died (app closed
        // while service kept running) and its port is now closed.  The sink will
        // be replaced with a fresh one the next time the main isolate calls
        // create_sync_progress_stream().
        let _ = stream_sink.add(scan_progress);
    }
}

pub(crate) fn send_sync_update(update: StateUpdate) -> anyhow::Result<()> {
    let stream_sink = STATE_UPDATE_STREAM_SINK
        .try_lock()
        .map_err(|_| anyhow::Error::msg("Stream sink not available"))?;
    match stream_sink.as_ref() {
        Some(sink) => sink
            .add(update)
            .map_err(|_| anyhow::Error::msg("error while sending sync update".to_string())),
        None => Err(anyhow::Error::msg("Stream sink not available".to_string())),
    }
}

pub(crate) fn send_tx_broadcast_update(update: String) -> anyhow::Result<()> {
    let stream_sink = TX_BROADCAST_STREAM_SINK
        .try_lock()
        .map_err(|_| anyhow::Error::msg("Stream sink not available"))?;
    match stream_sink.as_ref() {
        Some(sink) => sink
            .add(update)
            .map_err(|_| anyhow::Error::msg("error while sending broadcast update".to_string())),
        None => Err(anyhow::Error::msg("Stream sink not available".to_string())),
    }
}

pub fn create_frigate_event_stream(s: StreamSink<FrigateEventDto>) {
    let mut stream_sink = FRIGATE_EVENT_STREAM_SINK.lock().unwrap();
    *stream_sink = Some(s);
}

pub(crate) fn send_frigate_event(event: FrigateEventDto) -> anyhow::Result<()> {
    let stream_sink = FRIGATE_EVENT_STREAM_SINK
        .try_lock()
        .map_err(|_| anyhow::Error::msg("frigate event stream sink busy"))?;
    match stream_sink.as_ref() {
        Some(sink) => sink
            .add(event)
            .map_err(|_| anyhow::Error::msg("error while sending frigate event".to_string())),
        None => Err(anyhow::Error::msg("frigate event stream sink not available".to_string())),
    }
}
