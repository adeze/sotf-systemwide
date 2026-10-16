use super::misc::parameter_descriptor_to_json;
use serde_json::Value;
use sotf_audio::plugins::PluginType;

pub(super) fn plugin_parameter_descriptors(settings: &sotf_audio::PluginSettings) -> Vec<Value> {
    settings
        .param_specs()
        .iter()
        .map(parameter_descriptor_to_json)
        .collect()
}

/// Map PluginType enum to the string the engine's create_plugin() expects
pub(super) fn plugin_type_to_engine_str(pt: &PluginType) -> &'static str {
    pt.wire_name()
}

/// Categorize plugins for the UI picker.
///
/// This mirrors the canonical player grouping
/// (`sotf_audio_player::plugin_categories::CATEGORIES`, shared by the TUI,
/// GPUI rack, and GPUI rack-detail pickers) so every SOTF frontend renders
/// the same categories. It is mirrored rather than reused because the
/// daemon must not depend on the heavy `sotf-player` crate for six strings;
/// keep the two in sync when the canonical table changes.
pub(super) fn plugin_type_category(pt: &PluginType) -> &'static str {
    match pt {
        PluginType::Compressor
        | PluginType::Limiter
        | PluginType::Gate
        | PluginType::Expander
        | PluginType::MultibandCompressor
        | PluginType::MultibandExpander
        | PluginType::TransientShaper
        | PluginType::DeEsser
        | PluginType::Saturation
        | PluginType::DynamicEq
        | PluginType::SpectralCompressor
        | PluginType::AnalogCompressor
        | PluginType::AnalogLimiter => "Dynamics",
        PluginType::EQ
        | PluginType::LinearPhaseEq
        | PluginType::AnalogEq
        | PluginType::Gain
        | PluginType::Delay
        | PluginType::LoudnessCompensation
        | PluginType::Dither => "EQ & Tone",
        PluginType::Denoiser
        | PluginType::Declick
        | PluginType::HissReducer
        | PluginType::SpeechDenoiser
        | PluginType::Aec
        | PluginType::Pnd => "Denoising",
        PluginType::Upmixer
        | PluginType::Matrix
        | PluginType::BinauralDecoder
        | PluginType::Convolution
        | PluginType::XTC
        | PluginType::Crossfeed
        | PluginType::Beamformer
        | PluginType::AmbisonicsDecoder
        | PluginType::AAE
        | PluginType::StereoImager
        | PluginType::Downmix
        | PluginType::MonoToStereo => "Spatial",
        PluginType::LoudnessMonitor | PluginType::SpectrumAnalyzer | PluginType::ABCompare => {
            "Analysis"
        }
        PluginType::ChannelMuteSolo
        | PluginType::Crossover
        | PluginType::BandSplit
        | PluginType::BandMerge => "Routing",
        // Not in the canonical picker categories: FletcherMunson is
        // superseded by LoudnessCompensation (and excluded from the daemon
        // response); External is never a generic picker entry.
        PluginType::FletcherMunson => "Legacy",
        PluginType::External => "External",
    }
}

/// Install the authorized-runtime external-plugin sandbox for this process.
///
/// `sotf-player` installs these options at app startup; the daemon loads
/// chains without a UI host, so without this the isolated worker ran with
/// the narrower parameter-derived policy (no preset root, no granted media
/// paths) and external plugins behaved worse here than in the player. The
/// install is best-effort: on failure external plugins keep the default
/// isolated policy, which is still sandboxed.
#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub(super) fn install_plugin_sandbox() {
    match try_install_plugin_sandbox() {
        Ok(()) => log::info!("Installed authorized-runtime plugin sandbox options"),
        Err(error) => log::warn!(
            "Plugin sandbox options not installed ({error}); external plugins keep the default isolated policy"
        ),
    }
}

#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
fn try_install_plugin_sandbox() -> Result<(), String> {
    // Same layout as sotf-player's app config (its config/get.rs is the
    // canonical owner): grants at <config>/plugin_sandbox_grants.json,
    // presets under <config>/plugin_presets.
    let config_dir = player_app_config_dir()?;
    let grants_path = config_dir.join("plugin_sandbox_grants.json");
    let grants: sotf_plugins::PluginSandboxGrantStore = if grants_path.exists() {
        let text = std::fs::read_to_string(&grants_path)
            .map_err(|error| format!("cannot read {}: {error}", grants_path.display()))?;
        serde_json::from_str(&text)
            .map_err(|error| format!("invalid {}: {error}", grants_path.display()))?
    } else {
        sotf_plugins::PluginSandboxGrantStore::default()
    };
    let preset_root = config_dir.join("plugin_presets");
    std::fs::create_dir_all(&preset_root)
        .map_err(|error| format!("cannot create {}: {error}", preset_root.display()))?;
    let mut media_read_paths = sotf_plugins::default_plugin_sandbox_protected_media_paths();
    let recordings_dir = config_dir.join("Recordings");
    if recordings_dir.is_dir() {
        media_read_paths.push(recordings_dir);
    }
    let options = sotf_plugins::SandboxedPluginCreationOptions::authorized_runtime(
        grants,
        preset_root,
        media_read_paths,
    );
    sotf_plugins::set_default_sandboxed_plugin_creation_options(Some(options));
    Ok(())
}

/// App config directory using sotf-player's per-platform layout.
#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
fn player_app_config_dir() -> Result<std::path::PathBuf, String> {
    // Exactly one of these bindings survives cfg selection per target.
    #[cfg(target_os = "macos")]
    let dir = {
        let home = std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .ok_or("HOME is not set")?;
        std::path::PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("org.spinorama.sotf")
    };
    #[cfg(target_os = "windows")]
    let dir = match std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty()) {
        Some(local) => std::path::PathBuf::from(local).join("sotf"),
        None => {
            let profile = std::env::var_os("USERPROFILE")
                .filter(|value| !value.is_empty())
                .ok_or("neither LOCALAPPDATA nor USERPROFILE is set")?;
            std::path::PathBuf::from(profile)
                .join(".config")
                .join("sotf")
        }
    };
    #[cfg(target_os = "linux")]
    let dir = {
        let home = std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .ok_or("HOME is not set")?;
        std::path::PathBuf::from(home).join(".config").join("sotf")
    };
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concrete_external_plugin_has_daemon_metadata_without_a_generic_picker_entry() {
        assert_eq!(plugin_type_to_engine_str(&PluginType::External), "external");
        assert_eq!(plugin_type_category(&PluginType::External), "External");
        assert!(!PluginType::all().contains(&PluginType::External));
    }

    #[test]
    fn every_picker_plugin_uses_the_engine_wire_name() {
        for plugin_type in PluginType::all() {
            assert_eq!(
                plugin_type_to_engine_str(&plugin_type),
                plugin_type.wire_name()
            );
        }
        assert_eq!(plugin_type_category(&PluginType::Dither), "EQ & Tone");
        assert_eq!(plugin_type_category(&PluginType::AnalogEq), "EQ & Tone");
        assert_eq!(
            plugin_type_category(&PluginType::AnalogCompressor),
            "Dynamics"
        );
        assert_eq!(plugin_type_category(&PluginType::AnalogLimiter), "Dynamics");
    }
}
