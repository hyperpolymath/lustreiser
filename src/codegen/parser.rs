// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Node definition parser for lustreiser.
//
// Takes the validated manifest and produces `ParsedNode` structures that
// the Lustre and C generators consume. This stage resolves signal types,
// rate divisors, and infers which temporal operators are needed.

use anyhow::{Context, Result};

use crate::abi::{Clock, Signal, SignalType};
use crate::manifest::{self, Manifest, NodeConfig};

// ---------------------------------------------------------------------------
// ParsedNode — fully resolved node ready for code generation
// ---------------------------------------------------------------------------

/// A fully resolved Lustre node, ready for code generation.
/// All signal types are resolved to `SignalType` enums and rates are validated.
#[derive(Debug, Clone)]
pub struct ParsedNode {
    /// Node name.
    pub name: String,
    /// Resolved input signals.
    pub inputs: Vec<Signal>,
    /// Resolved output signals.
    pub outputs: Vec<Signal>,
    /// Base clock.
    pub clock: Clock,
    /// Number of temporal operators inferred from multi-rate signals.
    /// Each sub-rate signal requires a `when` operator; merging complementary
    /// signals requires a `merge` operator.
    pub operator_count: u32,
    /// Whether this node has multi-rate signals (requires clock calculus).
    pub is_multi_rate: bool,
}

// ---------------------------------------------------------------------------
// Parsing logic
// ---------------------------------------------------------------------------

/// Parse all node definitions from the manifest into `ParsedNode` structures.
///
/// For each `[[nodes]]` entry:
/// 1. Parse input/output signal specs ("name:type" or "name:type@rate")
/// 2. Resolve type strings to `SignalType` enums
/// 3. Build `Signal` structs with validated rates
/// 4. Infer operator count from multi-rate signals
pub fn parse_nodes(manifest: &Manifest) -> Result<Vec<ParsedNode>> {
    let mut parsed = Vec::with_capacity(manifest.nodes.len());
    for (i, node_cfg) in manifest.nodes.iter().enumerate() {
        let ctx = format!("nodes[{}] ('{}')", i, node_cfg.name);
        let pn = parse_single_node(node_cfg)
            .with_context(|| format!("Failed to parse {}", ctx))?;
        parsed.push(pn);
    }
    Ok(parsed)
}

/// Parse a single node configuration into a `ParsedNode`.
fn parse_single_node(cfg: &NodeConfig) -> Result<ParsedNode> {
    let clock = Clock::new(cfg.clock.base_period_ms)
        .ok_or_else(|| anyhow::anyhow!("clock.base-period-ms must be > 0"))?;

    let inputs = parse_signals(&cfg.inputs, "input")?;
    let outputs = parse_signals(&cfg.outputs, "output")?;

    // Determine if the node is multi-rate.
    let is_multi_rate = inputs.iter().chain(outputs.iter()).any(|s| s.rate > 1);

    // Infer operator count: each sub-rate signal needs a `when` operator for
    // down-sampling, plus one `merge` per output that combines rates.
    let sub_rate_count = inputs
        .iter()
        .chain(outputs.iter())
        .filter(|s| s.rate > 1)
        .count() as u32;
    let operator_count = if is_multi_rate {
        sub_rate_count + outputs.len() as u32
    } else {
        // Even single-rate nodes typically use at least one `pre` or `fby`
        // for state (e.g. integrators, filters).
        outputs.len() as u32
    };

    Ok(ParsedNode {
        name: cfg.name.clone(),
        inputs,
        outputs,
        clock,
        operator_count,
        is_multi_rate,
    })
}

/// Parse a list of signal specification strings into `Signal` structs.
fn parse_signals(specs: &[String], direction: &str) -> Result<Vec<Signal>> {
    let mut signals = Vec::with_capacity(specs.len());
    for spec in specs {
        let parsed = manifest::parse_signal(spec)
            .with_context(|| format!("Bad {} signal spec: '{}'", direction, spec))?;

        let signal_type: SignalType = parsed
            .signal_type
            .parse()
            .map_err(|e: String| anyhow::anyhow!("{}", e))?;

        signals.push(Signal::with_rate(parsed.name, signal_type, parsed.rate));
    }
    Ok(signals)
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::*;

    /// Helper: build a minimal valid manifest with one node.
    fn minimal_manifest(inputs: Vec<&str>, outputs: Vec<&str>) -> Manifest {
        Manifest {
            project: ProjectConfig {
                name: "test".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![NodeConfig {
                name: "ctrl".to_string(),
                inputs: inputs.into_iter().map(String::from).collect(),
                outputs: outputs.into_iter().map(String::from).collect(),
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
        }
    }

    #[test]
    fn test_parse_single_rate_node() {
        let m = minimal_manifest(vec!["x:int"], vec!["y:int"]);
        let nodes = parse_nodes(&m).unwrap();
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].name, "ctrl");
        assert_eq!(nodes[0].inputs.len(), 1);
        assert_eq!(nodes[0].outputs.len(), 1);
        assert!(!nodes[0].is_multi_rate);
        assert_eq!(nodes[0].inputs[0].signal_type, SignalType::Int);
        assert_eq!(nodes[0].inputs[0].rate, 1);
    }

    #[test]
    fn test_parse_multi_rate_node() {
        let m = minimal_manifest(
            vec!["fast:real", "slow:real@10"],
            vec!["out:real"],
        );
        let nodes = parse_nodes(&m).unwrap();
        assert!(nodes[0].is_multi_rate);
        assert_eq!(nodes[0].inputs[1].rate, 10);
        assert!(nodes[0].operator_count > 0);
    }

    #[test]
    fn test_parse_bad_type() {
        let m = minimal_manifest(vec!["x:quaternion"], vec!["y:int"]);
        assert!(parse_nodes(&m).is_err());
    }

    #[test]
    fn test_parse_multiple_nodes() {
        let m = Manifest {
            project: ProjectConfig {
                name: "multi".to_string(),
                version: "0.1.0".to_string(),
            },
            nodes: vec![
                NodeConfig {
                    name: "sensor".to_string(),
                    inputs: vec!["raw:int".to_string()],
                    outputs: vec!["filtered:real".to_string()],
                    clock: ClockConfig { base_period_ms: 5 },
                },
                NodeConfig {
                    name: "actuator".to_string(),
                    inputs: vec!["cmd:real".to_string()],
                    outputs: vec!["pwm:int".to_string()],
                    clock: ClockConfig { base_period_ms: 10 },
                },
            ],
            target: TargetConfig {
                platform: "riscv".to_string(),
                safety_standard: "IEC-61508".to_string(),
            },
            timing: TimingConfig {
                deadline_us: 2000,
                wcet_analysis: false,
            },
            workload: None,
            data: None,
            options: None,
        };
        let nodes = parse_nodes(&m).unwrap();
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].name, "sensor");
        assert_eq!(nodes[1].name, "actuator");
    }
}
