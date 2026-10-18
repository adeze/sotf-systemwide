use std::collections::HashMap;
use std::time::{Duration, Instant};

use cpal::traits::DeviceTrait;
use serde_json::Value;

use super::misc::list_audio_devices;

const DEVICE_CACHE_TTL: Duration = Duration::from_secs(2);

#[derive(Debug)]
struct Cached<T> {
    observed_at: Instant,
    value: T,
}

impl<T> Cached<T> {
    fn is_fresh(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.observed_at) <= DEVICE_CACHE_TTL
    }
}

/// Bounded daemon-owned view of CoreAudio/CPAL device capabilities.
///
/// CoreAudio enumeration and `supported_output_configs` probing are
/// synchronous and can each take hundreds of milliseconds. ConfigBar polls
/// device recovery every second, and RoomEQ validation used to repeat the
/// same probe for every file. This registry coalesces those reads while a
/// short TTL guarantees hot-plug changes become visible without preserving
/// stale capabilities indefinitely.
#[derive(Debug, Default)]
pub(super) struct DeviceRegistry {
    generation: u64,
    devices: Option<Cached<Vec<Value>>>,
    max_output_channels: HashMap<(String, u32), Cached<usize>>,
    negotiated_sample_rates: HashMap<(String, u32), Cached<u32>>,
}

/// Pick the pipeline sample rate for one output device: the desired rate
/// when the device supports it, otherwise the device default rate when it
/// is one of the supported pipeline rates, else the highest supported rate
/// not exceeding the desired one (or the highest overall). Returns None
/// when the device supports none of the pipeline rates.
///
/// Without this check a stale 96 kHz HAL request drives a 48 kHz-max
/// interface with a 96 kHz stream config; the device clock then runs at
/// its own rate while processing assumes 96 kHz, which plays at the wrong
/// speed until the user re-selects the interface.
pub(super) fn pick_supported_sample_rate(
    desired: u32,
    ranges: &[(u32, u32)],
    default_rate: Option<u32>,
) -> Option<u32> {
    let supports = |rate: u32| ranges.iter().any(|&(min, max)| min <= rate && rate <= max);
    if supports(desired) {
        return Some(desired);
    }
    let candidates: Vec<u32> = super::consts::SUPPORTED_SAMPLE_RATES
        .into_iter()
        .filter(|&rate| supports(rate))
        .collect();
    if let Some(default_rate) = default_rate
        && candidates.contains(&default_rate)
    {
        return Some(default_rate);
    }
    candidates
        .iter()
        .copied()
        .filter(|&rate| rate <= desired)
        .max()
        .or_else(|| candidates.iter().copied().max())
}

impl DeviceRegistry {
    pub(super) fn list_devices(&mut self) -> Result<(u64, Vec<Value>), String> {
        let now = Instant::now();
        if let Some(cached) = &self.devices
            && cached.is_fresh(now)
        {
            return Ok((self.generation, cached.value.clone()));
        }

        let devices = list_audio_devices()?;
        self.generation = self.generation.saturating_add(1);
        self.devices = Some(Cached {
            observed_at: now,
            value: devices.clone(),
        });
        Ok((self.generation, devices))
    }

    pub(super) fn max_output_channels(
        &mut self,
        selected_device: &str,
        sample_rate: u32,
        lab_backend: bool,
    ) -> Result<usize, String> {
        if lab_backend {
            if selected_device != "Systemwide Lab Output" {
                return Err(format!(
                    "Lab backend cannot inspect physical output device '{selected_device}'"
                ));
            }
            if !super::consts::SUPPORTED_SAMPLE_RATES.contains(&sample_rate) {
                return Err(format!("Lab output does not support {sample_rate} Hz"));
            }
            return Ok(16);
        }
        let now = Instant::now();
        let key = (selected_device.to_string(), sample_rate);
        if let Some(cached) = self.max_output_channels.get(&key)
            && cached.is_fresh(now)
        {
            return Ok(cached.value);
        }

        let host = sotf_audio::devices::get_host_for_device(Some(selected_device));
        let device_name = sotf_audio::devices::strip_asio_prefix(selected_device);
        let device = sotf_audio::devices::find_device(&host, device_name, false)
            .map_err(|error| format!("Cannot inspect output device '{device_name}': {error}"))?;
        let max_channels = device
            .supported_output_configs()
            .map_err(|error| format!("Cannot inspect output formats for '{device_name}': {error}"))?
            .filter(|config| {
                config.min_sample_rate() <= sample_rate && sample_rate <= config.max_sample_rate()
            })
            .map(|config| usize::from(config.channels()))
            .max()
            .or_else(|| {
                device
                    .default_output_config()
                    .ok()
                    .map(|config| usize::from(config.channels()))
            })
            .ok_or_else(|| {
                format!("Output device '{device_name}' does not report a usable channel layout")
            })?;

        self.max_output_channels.insert(
            key,
            Cached {
                observed_at: now,
                value: max_channels,
            },
        );
        Ok(max_channels)
    }

    /// Negotiate the pipeline sample rate against one device's reported
    /// output ranges (see `pick_supported_sample_rate`). Errors when the
    /// device reports no usable pipeline rate; callers log and keep the
    /// desired rate in that case.
    pub(super) fn negotiate_sample_rate(
        &mut self,
        selected_device: &str,
        desired: u32,
        lab_backend: bool,
    ) -> Result<u32, String> {
        if lab_backend {
            if super::consts::SUPPORTED_SAMPLE_RATES.contains(&desired) {
                return Ok(desired);
            }
            return Err(format!("Lab output does not support {desired} Hz"));
        }
        let now = Instant::now();
        let key = (selected_device.to_string(), desired);
        if let Some(cached) = self.negotiated_sample_rates.get(&key)
            && cached.is_fresh(now)
        {
            return Ok(cached.value);
        }

        let host = sotf_audio::devices::get_host_for_device(Some(selected_device));
        let device_name = sotf_audio::devices::strip_asio_prefix(selected_device);
        let device = sotf_audio::devices::find_device(&host, device_name, false)
            .map_err(|error| format!("Cannot inspect output device '{device_name}': {error}"))?;
        let ranges: Vec<(u32, u32)> = device
            .supported_output_configs()
            .map_err(|error| format!("Cannot inspect output formats for '{device_name}': {error}"))?
            .map(|config| (config.min_sample_rate(), config.max_sample_rate()))
            .collect();
        let default_rate = device
            .default_output_config()
            .ok()
            .map(|config| config.sample_rate());
        let negotiated =
            pick_supported_sample_rate(desired, &ranges, default_rate).ok_or_else(|| {
                format!("Output device '{device_name}' supports none of the pipeline sample rates")
            })?;

        self.negotiated_sample_rates.insert(
            key,
            Cached {
                observed_at: now,
                value: negotiated,
            },
        );
        Ok(negotiated)
    }

    /// Test seam: pre-populate the negotiation cache so rate negotiation
    /// can be exercised without local audio hardware.
    #[cfg(test)]
    pub(super) fn seed_negotiated_sample_rate(
        &mut self,
        selected_device: &str,
        desired: u32,
        negotiated: u32,
    ) {
        self.negotiated_sample_rates.insert(
            (selected_device.to_string(), desired),
            Cached {
                observed_at: Instant::now(),
                value: negotiated,
            },
        );
    }

    pub(super) fn invalidate(&mut self) {
        self.generation = self.generation.saturating_add(1);
        self.devices = None;
        self.max_output_channels.clear();
        self.negotiated_sample_rates.clear();
    }

    #[cfg(test)]
    pub(super) fn seed_max_output_channels(
        &mut self,
        selected_device: &str,
        sample_rate: u32,
        channels: usize,
    ) {
        self.max_output_channels.insert(
            (selected_device.to_string(), sample_rate),
            Cached {
                observed_at: Instant::now(),
                value: channels,
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_sample_rate_keeps_supported_desired_rate() {
        // Fireface-class range: 96 kHz is inside, keep it.
        assert_eq!(
            pick_supported_sample_rate(96_000, &[(32_000, 192_000)], Some(48_000)),
            Some(96_000)
        );
    }

    #[test]
    fn pick_sample_rate_falls_back_to_device_default_when_desired_unsupported() {
        // Startup regression: HAL still requests 96 kHz from the previous
        // session but the interface tops out at 48 kHz (ADAM D3V class).
        assert_eq!(
            pick_supported_sample_rate(96_000, &[(32_000, 48_000)], Some(48_000)),
            Some(48_000)
        );
        // Without a usable default, take the highest supported pipeline rate.
        assert_eq!(
            pick_supported_sample_rate(96_000, &[(32_000, 48_000)], None),
            Some(48_000)
        );
        // Same-device rates can also move up between sessions.
        assert_eq!(
            pick_supported_sample_rate(44_100, &[(88_200, 192_000)], None),
            Some(192_000)
        );
        // No pipeline rate in range: report none so the caller keeps desired.
        assert_eq!(
            pick_supported_sample_rate(48_000, &[(8_000, 11_025)], None),
            None
        );
    }

    #[test]
    fn cached_observation_expires_at_the_device_ttl() {
        let now = Instant::now();
        let fresh = Cached {
            observed_at: now,
            value: 2,
        };
        let stale = Cached {
            observed_at: now - DEVICE_CACHE_TTL - Duration::from_millis(1),
            value: 2,
        };

        assert!(fresh.is_fresh(now));
        assert!(!stale.is_fresh(now));
    }
}
