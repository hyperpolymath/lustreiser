// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Manifest parser for lustreiser.toml.
//
// The manifest describes a Lustre project: its nodes, target platform,
// safety standard, and timing constraints. The parser validates the TOML
// structure and produces a `Manifest` that drives code generation.
//
// Manifest structure:
//   [project]     — project name and version
//   [[nodes]]     — one or more Lustre node definitions
//   [target]      — embedded platform and safety certification
//   [timing]      — deadlines and WCET analysis toggle

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

// ---------------------------------------------------------------------------
// Top-level manifest
// ---------------------------------------------------------------------------

/// Top-level lustreiser manifest, parsed from `lustreiser.toml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    /// Project metadata.
    pub project: ProjectConfig,
    /// One or more Lustre node definitions.
    #[serde(rename = "nodes")]
    pub nodes: Vec<NodeConfig>,
    /// Target platform and safety standard.
    pub target: TargetConfig,
    /// Timing constraints.
    pub timing: TimingConfig,

    // Legacy compatibility fields (hidden from public API).
    // These allow the old `[workload]` / `[data]` format to still parse,
    // but they are not used by the new codegen pipeline.
    #[serde(default, skip_serializing)]
    pub workload: Option<LegacyWorkloadConfig>,
    #[serde(default, skip_serializing)]
    pub data: Option<LegacyDataConfig>,
    #[serde(default, skip_serializing)]
    pub options: Option<LegacyOptions>,
}

// ---------------------------------------------------------------------------
// [project]
// ---------------------------------------------------------------------------

/// Project metadata from the `[project]` section.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectConfig {
    /// Human-readable project name.
    pub name: String,
    /// Semantic version string.
    #[serde(default = "default_version")]
    pub version: String,
}

fn default_version() -> String {
    "0.1.0".to_string()
}

// ---------------------------------------------------------------------------
// [[nodes]]
// ---------------------------------------------------------------------------

/// A single Lustre node definition from the `[[nodes]]` array.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeConfig {
    /// Node name (must be a valid C/Lustre identifier).
    pub name: String,
    /// Input signal definitions. Each entry is "name:type" or "name:type@rate".
    pub inputs: Vec<String>,
    /// Output signal definitions. Same format as inputs.
    pub outputs: Vec<String>,
    /// Clock configuration for this node.
    pub clock: ClockConfig,
}

/// Clock configuration nested inside a node definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClockConfig {
    /// Base period in milliseconds.
    #[serde(rename = "base-period-ms")]
    pub base_period_ms: u64,
}

// ---------------------------------------------------------------------------
// [target]
// ---------------------------------------------------------------------------

/// Target platform and safety certification from the `[target]` section.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetConfig {
    /// Target platform: "arm-cortex-m", "riscv", or "x86".
    pub platform: String,
    /// Safety standard: "DO-178C", "IEC-61508", or "ISO-26262".
    #[serde(rename = "safety-standard")]
    pub safety_standard: String,
}

// ---------------------------------------------------------------------------
// [timing]
// ---------------------------------------------------------------------------

/// Timing constraints from the `[timing]` section.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingConfig {
    /// Hard deadline in microseconds. If any node's WCET exceeds this,
    /// the system cannot guarantee real-time correctness.
    #[serde(rename = "deadline-us")]
    pub deadline_us: u64,
    /// Whether to perform WCET analysis during code generation.
    #[serde(rename = "wcet-analysis", default = "default_true")]
    pub wcet_analysis: bool,
}

fn default_true() -> bool {
    true
}

// ---------------------------------------------------------------------------
// Legacy compat types (for old [workload]/[data] format)
// ---------------------------------------------------------------------------

/// Legacy `[workload]` section — kept for backward compatibility only.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LegacyWorkloadConfig {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub entry: String,
    #[serde(default)]
    pub strategy: String,
}

/// Legacy `[data]` section — kept for backward compatibility only.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LegacyDataConfig {
    #[serde(rename = "input-type", default)]
    pub input_type: String,
    #[serde(rename = "output-type", default)]
    pub output_type: String,
}

/// Legacy `[options]` section — kept for backward compatibility only.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct LegacyOptions {
    #[serde(default)]
    pub flags: Vec<String>,
}

// ---------------------------------------------------------------------------
// Signal parsing
// ---------------------------------------------------------------------------

/// Parsed signal from a manifest input/output string.
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedSignal {
    /// Signal name.
    pub name: String,
    /// Signal type string (e.g. "bool", "int", "real").
    pub signal_type: String,
    /// Rate divisor (1 = base rate).
    pub rate: u32,
}

/// Parse a signal specification string.
/// Accepted formats:
///   "name:type"       — signal at base rate
///   "name:type@rate"  — signal at the given rate divisor
///
/// Examples:
///   "pitch:real"      => ParsedSignal { name: "pitch", signal_type: "real", rate: 1 }
///   "gps_lat:real@10" => ParsedSignal { name: "gps_lat", signal_type: "real", rate: 10 }
pub fn parse_signal(spec: &str) -> Result<ParsedSignal> {
    let spec = spec.trim();
    let (name_type, rate) = if let Some((left, right)) = spec.rsplit_once('@') {
        let rate: u32 = right
            .trim()
            .parse()
            .with_context(|| format!("Invalid rate in signal spec '{}': '{}' is not a number", spec, right.trim()))?;
        if rate == 0 {
            anyhow::bail!("Rate must be >= 1 in signal spec '{}'", spec);
        }
        (left, rate)
    } else {
        (spec, 1u32)
    };

    let (name, signal_type) = name_type
        .split_once(':')
        .with_context(|| format!("Signal spec '{}' must be 'name:type' or 'name:type@rate'", spec))?;

    let name = name.trim().to_string();
    let signal_type = signal_type.trim().to_string();

    if name.is_empty() {
        anyhow::bail!("Signal name must not be empty in spec '{}'", spec);
    }
    if signal_type.is_empty() {
        anyhow::bail!("Signal type must not be empty in spec '{}'", spec);
    }

    Ok(ParsedSignal {
        name,
        signal_type,
        rate,
    })
}

// ---------------------------------------------------------------------------
// Load / validate / init / info
// ---------------------------------------------------------------------------

/// Load a manifest from the given TOML file path.
pub fn load_manifest(path: &str) -> Result<Manifest> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read manifest: {}", path))?;
    toml::from_str(&content)
        .with_context(|| format!("Failed to parse manifest: {}", path))
}

/// Validate a loaded manifest for correctness.
///
/// Checks:
/// - Project name is non-empty
/// - At least one node is defined
/// - Each node has a valid name, at least one input, at least one output
/// - All signal specs parse correctly and have known types
/// - Clock base period > 0
/// - Target platform and safety standard are recognised
/// - Deadline > 0
pub fn validate(manifest: &Manifest) -> Result<()> {
    // Project
    if manifest.project.name.is_empty() {
        anyhow::bail!("project.name is required");
    }

    // Nodes
    if manifest.nodes.is_empty() {
        anyhow::bail!("At least one [[nodes]] entry is required");
    }

    let valid_types = ["bool", "boolean", "int", "int32", "integer", "float", "f32", "real", "double", "f64"];

    for (i, node) in manifest.nodes.iter().enumerate() {
        let ctx = format!("nodes[{}] ('{}')", i, node.name);

        if node.name.is_empty() {
            anyhow::bail!("{}: name must not be empty", ctx);
        }
        if !node.name.chars().next().unwrap().is_ascii_alphabetic()
            && node.name.chars().next().unwrap() != '_'
        {
            anyhow::bail!("{}: name must start with a letter or underscore", ctx);
        }

        if node.inputs.is_empty() {
            anyhow::bail!("{}: must have at least one input", ctx);
        }
        if node.outputs.is_empty() {
            anyhow::bail!("{}: must have at least one output", ctx);
        }

        // Parse and validate each signal.
        let mut signal_names = std::collections::HashSet::new();
        for spec in node.inputs.iter().chain(node.outputs.iter()) {
            let parsed = parse_signal(spec)
                .with_context(|| format!("{}: invalid signal spec", ctx))?;
            if !signal_names.insert(parsed.name.clone()) {
                anyhow::bail!("{}: duplicate signal name '{}'", ctx, parsed.name);
            }
            if !valid_types.contains(&parsed.signal_type.to_lowercase().as_str()) {
                anyhow::bail!(
                    "{}: unknown signal type '{}' in '{}'. Valid types: bool, int, float, real",
                    ctx, parsed.signal_type, spec
                );
            }
        }

        // Clock
        if node.clock.base_period_ms == 0 {
            anyhow::bail!("{}: clock.base-period-ms must be > 0", ctx);
        }
    }

    // Target
    let valid_platforms = ["arm-cortex-m", "riscv", "x86"];
    if !valid_platforms.contains(&manifest.target.platform.to_lowercase().as_str()) {
        anyhow::bail!(
            "target.platform '{}' is not recognised. Valid: {:?}",
            manifest.target.platform,
            valid_platforms
        );
    }

    let valid_standards = ["DO-178C", "IEC-61508", "ISO-26262"];
    if !valid_standards.contains(&manifest.target.safety_standard.as_str()) {
        anyhow::bail!(
            "target.safety-standard '{}' is not recognised. Valid: {:?}",
            manifest.target.safety_standard,
            valid_standards
        );
    }

    // Timing
    if manifest.timing.deadline_us == 0 {
        anyhow::bail!("timing.deadline-us must be > 0");
    }

    Ok(())
}

/// Create a new lustreiser.toml manifest template at the given path.
pub fn init_manifest(path: &str) -> Result<()> {
    let manifest_path = Path::new(path).join("lustreiser.toml");
    if manifest_path.exists() {
        anyhow::bail!("lustreiser.toml already exists");
    }
    let template = r#"# lustreiser manifest — synchronous dataflow code generation
# SPDX-License-Identifier: PMPL-1.0-or-later

[project]
name = "my-controller"
version = "0.1.0"

[[nodes]]
name = "controller"
inputs = ["sensor_in:real"]
outputs = ["actuator_out:real"]

[nodes.clock]
base-period-ms = 10

[target]
platform = "arm-cortex-m"
safety-standard = "DO-178C"

[timing]
deadline-us = 5000
wcet-analysis = true
"#;
    std::fs::write(&manifest_path, template)?;
    println!("Created {}", manifest_path.display());
    Ok(())
}

/// Print human-readable info about a manifest.
pub fn print_info(manifest: &Manifest) {
    println!("=== {} v{} ===", manifest.project.name, manifest.project.version);
    println!("Target:   {} ({})", manifest.target.platform, manifest.target.safety_standard);
    println!("Deadline: {}us (WCET analysis: {})", manifest.timing.deadline_us, manifest.timing.wcet_analysis);
    println!("Nodes:");
    for node in &manifest.nodes {
        println!("  {} — clock: {}ms", node.name, node.clock.base_period_ms);
        for input in &node.inputs {
            println!("    in:  {}", input);
        }
        for output in &node.outputs {
            println!("    out: {}", output);
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_signal_basic() {
        let s = parse_signal("pitch:real").unwrap();
        assert_eq!(s.name, "pitch");
        assert_eq!(s.signal_type, "real");
        assert_eq!(s.rate, 1);
    }

    #[test]
    fn test_parse_signal_with_rate() {
        let s = parse_signal("gps_lat:real@10").unwrap();
        assert_eq!(s.name, "gps_lat");
        assert_eq!(s.signal_type, "real");
        assert_eq!(s.rate, 10);
    }

    #[test]
    fn test_parse_signal_trimming() {
        let s = parse_signal("  temp : float @ 5 ").unwrap();
        assert_eq!(s.name, "temp");
        assert_eq!(s.signal_type, "float");
        assert_eq!(s.rate, 5);
    }

    #[test]
    fn test_parse_signal_bad_format() {
        assert!(parse_signal("no_colon").is_err());
        assert!(parse_signal(":type").is_err());
        assert!(parse_signal("name:").is_err());
        assert!(parse_signal("name:type@0").is_err());
        assert!(parse_signal("name:type@abc").is_err());
    }

    #[test]
    fn test_validate_minimal_manifest() {
        let manifest = Manifest {
            project: ProjectConfig {
                name: "test".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![NodeConfig {
                name: "ctrl".to_string(),
                inputs: vec!["x:int".to_string()],
                outputs: vec!["y:int".to_string()],
                clock: ClockConfig { base_period_ms: 10 },
            }],
            target: TargetConfig {
                platform: "arm-cortex-m".to_string(),
                safety_standard: "DO-178C".to_string(),
            },
            timing: TimingConfig {
                deadline_us: 5000,
                wcet_analysis: true,
            },
            workload: None,
            data: None,
            options: None,
        };
        assert!(validate(&manifest).is_ok());
    }

    #[test]
    fn test_validate_empty_project_name() {
        let manifest = Manifest {
            project: ProjectConfig {
                name: "".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![NodeConfig {
                name: "ctrl".to_string(),
                inputs: vec!["x:int".to_string()],
                outputs: vec!["y:int".to_string()],
                clock: ClockConfig { base_period_ms: 10 },
            }],
            target: TargetConfig {
                platform: "arm-cortex-m".to_string(),
                safety_standard: "DO-178C".to_string(),
            },
            timing: TimingConfig {
                deadline_us: 5000,
                wcet_analysis: true,
            },
            workload: None,
            data: None,
            options: None,
        };
        assert!(validate(&manifest).is_err());
    }

    #[test]
    fn test_validate_no_nodes() {
        let manifest = Manifest {
            project: ProjectConfig {
                name: "test".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![],
            target: TargetConfig {
                platform: "x86".to_string(),
                safety_standard: "ISO-26262".to_string(),
            },
            timing: TimingConfig {
                deadline_us: 1000,
                wcet_analysis: false,
            },
            workload: None,
            data: None,
            options: None,
        };
        let err = validate(&manifest).unwrap_err();
        assert!(err.to_string().contains("At least one"));
    }

    #[test]
    fn test_validate_bad_platform() {
        let manifest = Manifest {
            project: ProjectConfig {
                name: "test".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![NodeConfig {
                name: "n".to_string(),
                inputs: vec!["a:bool".to_string()],
                outputs: vec!["b:bool".to_string()],
                clock: ClockConfig { base_period_ms: 1 },
            }],
            target: TargetConfig {
                platform: "mips".to_string(),
                safety_standard: "DO-178C".to_string(),
            },
            timing: TimingConfig {
                deadline_us: 100,
                wcet_analysis: true,
            },
            workload: None,
            data: None,
            options: None,
        };
        let err = validate(&manifest).unwrap_err();
        assert!(err.to_string().contains("not recognised"));
    }
}
