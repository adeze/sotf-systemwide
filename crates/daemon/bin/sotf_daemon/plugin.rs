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
