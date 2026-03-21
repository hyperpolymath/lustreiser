// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// lustreiser library API.
//
// Public modules:
// - `abi`      — domain types (LustreNode, Clock, TemporalOperator, etc.)
// - `manifest` — TOML manifest parsing and validation
// - `codegen`  — Lustre (.lus) and C code generation

pub mod abi;
pub mod codegen;
pub mod manifest;

pub use manifest::{load_manifest, validate, Manifest};

/// Convenience: load, validate, and generate all artifacts in one call.
pub fn generate(manifest_path: &str, output_dir: &str) -> anyhow::Result<()> {
    let m = load_manifest(manifest_path)?;
    validate(&m)?;
    codegen::generate_all(&m, output_dir)?;
    Ok(())
}
