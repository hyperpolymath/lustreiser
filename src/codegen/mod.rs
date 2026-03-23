// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Code generation pipeline for lustreiser.
//
// The pipeline has three stages:
//   1. parser    — validate node definitions from the manifest
//   2. lustre_gen — generate Lustre (.lus) files with clock calculus operators
//   3. c_gen     — generate deterministic C from the Lustre representation
//
// Each stage is a separate submodule for clarity and testability.

pub mod c_gen;
pub mod lustre_gen;
pub mod parser;

use anyhow::{Context, Result};
use std::fs;
use std::path::Path;

use crate::manifest::Manifest;

/// Generate all artifacts: Lustre .lus files and deterministic C code.
///
/// Output directory structure:
///   <output_dir>/
///     <node_name>.lus   — Lustre source for each node
///     <node_name>.c     — Generated C implementation
///     <node_name>.h     — Generated C header
///     wcet_report.txt   — WCET analysis report (if enabled)
pub fn generate_all(manifest: &Manifest, output_dir: &str) -> Result<()> {
    let out = Path::new(output_dir);
    fs::create_dir_all(out).context("Failed to create output directory")?;

    // Stage 1: Parse and validate node definitions from the manifest.
    let parsed_nodes = parser::parse_nodes(manifest).context("Failed to parse node definitions")?;

    // Stage 2: Generate Lustre (.lus) files.
    for node in &parsed_nodes {
        let lus_content = lustre_gen::generate_lustre_node(node);
        let lus_path = out.join(format!("{}.lus", node.name));
        fs::write(&lus_path, &lus_content)
            .with_context(|| format!("Failed to write {}", lus_path.display()))?;
    }

    // Stage 3: Generate C code from the parsed nodes.
    for node in &parsed_nodes {
        let (header, source) = c_gen::generate_c_node(node, manifest);
        let h_path = out.join(format!("{}.h", node.name));
        let c_path = out.join(format!("{}.c", node.name));
        fs::write(&h_path, &header)
            .with_context(|| format!("Failed to write {}", h_path.display()))?;
        fs::write(&c_path, &source)
            .with_context(|| format!("Failed to write {}", c_path.display()))?;
    }

    // Stage 4: WCET report (if analysis is enabled).
    if manifest.timing.wcet_analysis {
        let report = generate_wcet_report(&parsed_nodes, manifest);
        let report_path = out.join("wcet_report.txt");
        fs::write(&report_path, &report)
            .with_context(|| format!("Failed to write {}", report_path.display()))?;
    }

    Ok(())
}

/// Generate a WCET analysis report for all nodes.
/// This is a static estimation based on node complexity; a real tool chain
/// would integrate with aiT, Bound-T, or OTAWA for precise analysis.
fn generate_wcet_report(nodes: &[parser::ParsedNode], manifest: &Manifest) -> String {
    use crate::abi::{SafetyStandard, Wcet};

    let standard: SafetyStandard = manifest
        .target
        .safety_standard
        .parse()
        .unwrap_or(SafetyStandard::Do178c);

    let mut report = String::new();
    report.push_str("=== lustreiser WCET Analysis Report ===\n");
    report.push_str(&format!(
        "Project: {} v{}\n",
        manifest.project.name, manifest.project.version
    ));
    report.push_str(&format!(
        "Target: {} ({})\n",
        manifest.target.platform, manifest.target.safety_standard
    ));
    report.push_str(&format!("Deadline: {}us\n\n", manifest.timing.deadline_us));

    let mut all_pass = true;
    for node in nodes {
        // Static WCET estimation heuristic:
        // Base cost per node: 50us
        // Per input signal: 10us
        // Per output signal: 15us (includes output copy)
        // Per temporal operator: 20us (memory access for delay lines)
        let estimated_us: u64 = 50
            + (node.inputs.len() as u64 * 10)
            + (node.outputs.len() as u64 * 15)
            + (node.operator_count as u64 * 20);

        let wcet = Wcet::new(&node.name, estimated_us, manifest.timing.deadline_us, true);

        let compliant = wcet.satisfies_standard(&standard);
        if !compliant {
            all_pass = false;
        }

        report.push_str(&format!("{}\n", wcet));
        report.push_str(&format!(
            "  {} compliant: {}\n\n",
            standard.display_name(),
            if compliant {
                "YES"
            } else {
                "NO — margin insufficient"
            }
        ));
    }

    report.push_str(&format!(
        "Overall: {}\n",
        if all_pass {
            "ALL NODES PASS"
        } else {
            "SOME NODES FAIL — review WCET estimates"
        }
    ));

    report
}

/// Build generated artifacts (placeholder — would invoke a C cross-compiler).
pub fn build(manifest: &Manifest, _release: bool) -> Result<()> {
    println!(
        "Building lustreiser workload: {} (target: {})",
        manifest.project.name, manifest.target.platform
    );
    println!("  Cross-compiler target: {}", manifest.target.platform);
    println!("  Safety standard: {}", manifest.target.safety_standard);
    // In a real implementation this would invoke arm-none-eabi-gcc or similar.
    Ok(())
}

/// Run the generated workload (placeholder — would execute the compiled binary).
pub fn run(manifest: &Manifest, _args: &[String]) -> Result<()> {
    println!(
        "Running lustreiser workload: {} (target: {})",
        manifest.project.name, manifest.target.platform
    );
    // In a real implementation this would flash to target or run in a simulator.
    Ok(())
}
