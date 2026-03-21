// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// ABI module for lustreiser.
// Rust-side types mirroring the Idris2 ABI formal definitions.
// The Idris2 proofs guarantee correctness; this module provides runtime types.
//
// Core domain types for Lustre synchronous dataflow code generation:
// - LustreNode: a synchronous node with typed inputs/outputs and clock binding
// - Clock: base clock period for real-time scheduling
// - TemporalOperator: Pre, Fby, When, Merge — Lustre's clock calculus operators
// - SafetyStandard: DO-178C (avionics), IEC-61508 (industrial), ISO-26262 (automotive)
// - WCET: worst-case execution time analysis result
// - EmbeddedTarget: target platform (ARM Cortex-M, RISC-V, x86)

use serde::{Deserialize, Serialize};
use std::fmt;

// ---------------------------------------------------------------------------
// Clock — base timing unit for synchronous scheduling
// ---------------------------------------------------------------------------

/// Represents the base clock period for a Lustre node.
/// All signal rates are derived as integer multiples or divisions of this base.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Clock {
    /// Base period in milliseconds. Must be > 0.
    pub base_period_ms: u64,
}

impl Clock {
    /// Create a new clock with the given base period.
    /// Returns None if base_period_ms is zero.
    pub fn new(base_period_ms: u64) -> Option<Self> {
        if base_period_ms == 0 {
            None
        } else {
            Some(Self { base_period_ms })
        }
    }

    /// Compute the frequency in Hz from the base period.
    pub fn frequency_hz(&self) -> f64 {
        1000.0 / self.base_period_ms as f64
    }
}

impl fmt::Display for Clock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}ms ({:.1}Hz)", self.base_period_ms, self.frequency_hz())
    }
}

// ---------------------------------------------------------------------------
// TemporalOperator — Lustre's clock calculus operators
// ---------------------------------------------------------------------------

/// The four fundamental temporal operators in Lustre's clock calculus.
///
/// - `Pre`: access the previous value of a stream (unit delay)
/// - `Fby`: "followed by" — initialise then shift (sugar for `init -> pre x`)
/// - `When`: down-sample a stream on a boolean clock
/// - `Merge`: combine two complementary clocked streams into one
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TemporalOperator {
    /// `pre(x)` — unit delay; value at tick n is x at tick n-1.
    /// Undefined at tick 0 unless combined with Fby or an init expression.
    Pre,
    /// `init fby x` — "followed by". At tick 0 yields `init`, thereafter `pre(x)`.
    Fby {
        /// Name of the initial-value expression (resolved during codegen).
        init_expr: String,
    },
    /// `x when c` — sample stream `x` only when boolean clock `c` is true.
    /// The output stream runs at a slower clock than the input.
    When {
        /// Name of the boolean clock signal.
        clock_signal: String,
    },
    /// `merge(c, x, y)` — combine stream `x` (sampled when c) and `y` (sampled when not c).
    /// Produces a stream at the faster (parent) clock.
    Merge {
        /// Name of the boolean clock selector.
        clock_signal: String,
    },
}

impl fmt::Display for TemporalOperator {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pre => write!(f, "pre"),
            Self::Fby { init_expr } => write!(f, "{} fby", init_expr),
            Self::When { clock_signal } => write!(f, "when {}", clock_signal),
            Self::Merge { clock_signal } => write!(f, "merge({})", clock_signal),
        }
    }
}

// ---------------------------------------------------------------------------
// Signal types for Lustre I/O
// ---------------------------------------------------------------------------

/// Primitive signal types supported by the code generator.
/// These map directly to C types in the generated embedded code.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SignalType {
    /// Boolean signal (C: `bool` / `_Bool`).
    Bool,
    /// Signed 32-bit integer (C: `int32_t`).
    Int,
    /// IEEE 754 single-precision float (C: `float`).
    Float,
    /// IEEE 754 double-precision float (C: `double`).
    Real,
}

impl SignalType {
    /// Return the C type string for this signal type.
    pub fn c_type(&self) -> &'static str {
        match self {
            Self::Bool => "_Bool",
            Self::Int => "int32_t",
            Self::Float => "float",
            Self::Real => "double",
        }
    }

    /// Return the Lustre type string for this signal type.
    pub fn lustre_type(&self) -> &'static str {
        match self {
            Self::Bool => "bool",
            Self::Int => "int",
            Self::Float => "real",
            Self::Real => "real",
        }
    }
}

impl fmt::Display for SignalType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.lustre_type())
    }
}

/// Parse a signal type from a string. Case-insensitive.
impl std::str::FromStr for SignalType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "bool" | "boolean" => Ok(Self::Bool),
            "int" | "int32" | "integer" => Ok(Self::Int),
            "float" | "f32" => Ok(Self::Float),
            "real" | "double" | "f64" => Ok(Self::Real),
            other => Err(format!("Unknown signal type: '{}'. Expected bool, int, float, or real.", other)),
        }
    }
}

// ---------------------------------------------------------------------------
// Signal — a named, typed, rated I/O port
// ---------------------------------------------------------------------------

/// A named signal with a type and optional rate divisor.
/// The rate divisor determines how many base-clock ticks elapse between samples.
/// A rate of 1 means the signal runs at the base clock; 2 means half-rate, etc.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Signal {
    /// Signal name (must be a valid C identifier).
    pub name: String,
    /// Signal data type.
    pub signal_type: SignalType,
    /// Rate divisor relative to the node's base clock. Defaults to 1.
    pub rate: u32,
}

impl Signal {
    /// Create a new signal at the base rate.
    pub fn new(name: impl Into<String>, signal_type: SignalType) -> Self {
        Self {
            name: name.into(),
            signal_type,
            rate: 1,
        }
    }

    /// Create a new signal with a specific rate divisor.
    pub fn with_rate(name: impl Into<String>, signal_type: SignalType, rate: u32) -> Self {
        Self {
            name: name.into(),
            signal_type,
            rate: std::cmp::max(1, rate),
        }
    }
}

impl fmt::Display for Signal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.rate == 1 {
            write!(f, "{}: {}", self.name, self.signal_type)
        } else {
            write!(f, "{}: {} @/{}", self.name, self.signal_type, self.rate)
        }
    }
}

// ---------------------------------------------------------------------------
// LustreNode — a complete synchronous node definition
// ---------------------------------------------------------------------------

/// A Lustre node: the fundamental unit of synchronous computation.
/// Each node has typed inputs, typed outputs, a base clock, and an optional
/// body composed of equations using temporal operators.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LustreNode {
    /// Node name (must be a valid C/Lustre identifier).
    pub name: String,
    /// Input signals.
    pub inputs: Vec<Signal>,
    /// Output signals.
    pub outputs: Vec<Signal>,
    /// Base clock for this node.
    pub clock: Clock,
    /// Temporal operators used in the node body (for WCET analysis).
    pub operators: Vec<TemporalOperator>,
}

impl LustreNode {
    /// Create a new empty Lustre node.
    pub fn new(name: impl Into<String>, clock: Clock) -> Self {
        Self {
            name: name.into(),
            inputs: Vec::new(),
            outputs: Vec::new(),
            clock,
            operators: Vec::new(),
        }
    }

    /// Add an input signal.
    pub fn add_input(&mut self, signal: Signal) {
        self.inputs.push(signal);
    }

    /// Add an output signal.
    pub fn add_output(&mut self, signal: Signal) {
        self.outputs.push(signal);
    }

    /// Add a temporal operator to the node body.
    pub fn add_operator(&mut self, op: TemporalOperator) {
        self.operators.push(op);
    }

    /// Validate that the node definition is well-formed.
    /// Returns a list of error messages (empty means valid).
    pub fn validate(&self) -> Vec<String> {
        let mut errors = Vec::new();

        if self.name.is_empty() {
            errors.push("Node name must not be empty".to_string());
        }

        if !self.name.chars().next().map_or(false, |c| c.is_ascii_alphabetic() || c == '_') {
            errors.push(format!("Node name '{}' must start with a letter or underscore", self.name));
        }

        if self.inputs.is_empty() {
            errors.push(format!("Node '{}' must have at least one input", self.name));
        }

        if self.outputs.is_empty() {
            errors.push(format!("Node '{}' must have at least one output", self.name));
        }

        // Check for duplicate signal names across inputs and outputs.
        let mut seen = std::collections::HashSet::new();
        for sig in self.inputs.iter().chain(self.outputs.iter()) {
            if !seen.insert(&sig.name) {
                errors.push(format!("Duplicate signal name '{}' in node '{}'", sig.name, self.name));
            }
        }

        errors
    }
}

impl fmt::Display for LustreNode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "node {}(", self.name)?;
        for (i, input) in self.inputs.iter().enumerate() {
            if i > 0 {
                write!(f, "; ")?;
            }
            write!(f, "{}", input)?;
        }
        write!(f, ") returns (")?;
        for (i, output) in self.outputs.iter().enumerate() {
            if i > 0 {
                write!(f, "; ")?;
            }
            write!(f, "{}", output)?;
        }
        write!(f, ") -- clock: {}", self.clock)
    }
}

// ---------------------------------------------------------------------------
// SafetyStandard — certification targets
// ---------------------------------------------------------------------------

/// Safety certification standards for real-time embedded systems.
/// Each standard imposes specific requirements on code generation, testing,
/// traceability, and WCET analysis.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SafetyStandard {
    /// DO-178C — Software Considerations in Airborne Systems and Equipment Certification.
    /// Used in avionics. Levels A–E (A = catastrophic, E = no effect).
    #[serde(rename = "DO-178C")]
    Do178c,
    /// IEC 61508 — Functional Safety of Electrical/Electronic/Programmable Electronic
    /// Safety-related Systems. Used in industrial automation. SIL 1–4.
    #[serde(rename = "IEC-61508")]
    Iec61508,
    /// ISO 26262 — Road vehicles — Functional safety. Used in automotive.
    /// ASIL A–D (D = most stringent).
    #[serde(rename = "ISO-26262")]
    Iso26262,
}

impl SafetyStandard {
    /// Return the human-readable name of this standard.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Do178c => "DO-178C (Avionics)",
            Self::Iec61508 => "IEC 61508 (Industrial)",
            Self::Iso26262 => "ISO 26262 (Automotive)",
        }
    }

    /// Return the maximum allowed WCET margin percentage for this standard.
    /// More stringent standards require tighter WCET bounds.
    pub fn wcet_margin_percent(&self) -> f64 {
        match self {
            Self::Do178c => 10.0,   // 10% margin — very tight (avionics)
            Self::Iec61508 => 15.0, // 15% margin — tight (industrial)
            Self::Iso26262 => 20.0, // 20% margin — moderate (automotive)
        }
    }
}

impl fmt::Display for SafetyStandard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.display_name())
    }
}

impl std::str::FromStr for SafetyStandard {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_uppercase().replace(' ', "").replace('_', "-").as_str() {
            "DO-178C" | "DO178C" => Ok(Self::Do178c),
            "IEC-61508" | "IEC61508" => Ok(Self::Iec61508),
            "ISO-26262" | "ISO26262" => Ok(Self::Iso26262),
            other => Err(format!(
                "Unknown safety standard: '{}'. Expected DO-178C, IEC-61508, or ISO-26262.",
                other
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// EmbeddedTarget — target platform
// ---------------------------------------------------------------------------

/// Target embedded platform for code generation.
/// Determines compiler flags, memory model, and ABI conventions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EmbeddedTarget {
    /// ARM Cortex-M series (M0, M3, M4, M7, M33, etc.).
    /// Little-endian, Thumb-2 instruction set, hardware FPU on M4F/M7.
    #[serde(rename = "arm-cortex-m")]
    ArmCortexM,
    /// RISC-V (RV32IMAC or RV64GC).
    /// Open ISA, growing adoption in safety-critical domains.
    #[serde(rename = "riscv")]
    RiscV,
    /// x86/x86-64.
    /// Used for simulation, testing, and some industrial controllers.
    #[serde(rename = "x86")]
    X86,
}

impl EmbeddedTarget {
    /// Return the C compiler target triple for this platform.
    pub fn target_triple(&self) -> &'static str {
        match self {
            Self::ArmCortexM => "arm-none-eabi",
            Self::RiscV => "riscv32-unknown-elf",
            Self::X86 => "x86_64-unknown-linux-gnu",
        }
    }

    /// Return recommended compiler optimisation flags for this target.
    pub fn compiler_flags(&self) -> &'static [&'static str] {
        match self {
            Self::ArmCortexM => &["-mcpu=cortex-m4", "-mthumb", "-mfloat-abi=hard", "-mfpu=fpv4-sp-d16"],
            Self::RiscV => &["-march=rv32imac", "-mabi=ilp32"],
            Self::X86 => &["-march=native", "-O2"],
        }
    }
}

impl fmt::Display for EmbeddedTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.target_triple())
    }
}

impl std::str::FromStr for EmbeddedTarget {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().replace('_', "-").as_str() {
            "arm-cortex-m" | "arm" | "cortex-m" | "cortexm" => Ok(Self::ArmCortexM),
            "riscv" | "risc-v" | "rv32" => Ok(Self::RiscV),
            "x86" | "x86-64" | "x86_64" | "amd64" => Ok(Self::X86),
            other => Err(format!(
                "Unknown target: '{}'. Expected arm-cortex-m, riscv, or x86.",
                other
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// WCET — worst-case execution time analysis
// ---------------------------------------------------------------------------

/// Worst-case execution time (WCET) analysis result for a Lustre node.
/// WCET is critical for real-time scheduling: if any node exceeds its deadline,
/// the entire system fails to meet its timing guarantees.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Wcet {
    /// Name of the node this analysis applies to.
    pub node_name: String,
    /// Estimated WCET in microseconds.
    pub estimated_us: u64,
    /// Hard deadline in microseconds (from [timing] config).
    pub deadline_us: u64,
    /// Whether WCET analysis was actually performed (vs. estimated).
    pub analysis_performed: bool,
}

impl Wcet {
    /// Create a new WCET result.
    pub fn new(node_name: impl Into<String>, estimated_us: u64, deadline_us: u64, analysis_performed: bool) -> Self {
        Self {
            node_name: node_name.into(),
            estimated_us,
            deadline_us,
            analysis_performed,
        }
    }

    /// Check whether the node meets its deadline.
    pub fn meets_deadline(&self) -> bool {
        self.estimated_us <= self.deadline_us
    }

    /// Compute the slack (remaining time) in microseconds.
    /// Negative values indicate a deadline violation.
    pub fn slack_us(&self) -> i64 {
        self.deadline_us as i64 - self.estimated_us as i64
    }

    /// Compute the utilisation ratio (0.0–1.0+). Values > 1.0 indicate overload.
    pub fn utilisation(&self) -> f64 {
        if self.deadline_us == 0 {
            return f64::INFINITY;
        }
        self.estimated_us as f64 / self.deadline_us as f64
    }

    /// Check whether the WCET margin satisfies the given safety standard.
    pub fn satisfies_standard(&self, standard: &SafetyStandard) -> bool {
        if !self.meets_deadline() {
            return false;
        }
        let margin = 100.0 * (1.0 - self.utilisation());
        margin >= standard.wcet_margin_percent()
    }
}

impl fmt::Display for Wcet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let status = if self.meets_deadline() { "OK" } else { "VIOLATION" };
        write!(
            f,
            "WCET({}) = {}us / {}us deadline [{}] (utilisation: {:.1}%)",
            self.node_name,
            self.estimated_us,
            self.deadline_us,
            status,
            self.utilisation() * 100.0,
        )
    }
}

// ---------------------------------------------------------------------------
// Re-exports for convenience
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clock_creation() {
        assert!(Clock::new(0).is_none());
        let clk = Clock::new(10).unwrap();
        assert_eq!(clk.base_period_ms, 10);
        assert!((clk.frequency_hz() - 100.0).abs() < 0.001);
    }

    #[test]
    fn test_signal_type_parsing() {
        assert_eq!("bool".parse::<SignalType>().unwrap(), SignalType::Bool);
        assert_eq!("int".parse::<SignalType>().unwrap(), SignalType::Int);
        assert_eq!("float".parse::<SignalType>().unwrap(), SignalType::Float);
        assert_eq!("real".parse::<SignalType>().unwrap(), SignalType::Real);
        assert!("unknown".parse::<SignalType>().is_err());
    }

    #[test]
    fn test_signal_c_types() {
        assert_eq!(SignalType::Bool.c_type(), "_Bool");
        assert_eq!(SignalType::Int.c_type(), "int32_t");
        assert_eq!(SignalType::Float.c_type(), "float");
        assert_eq!(SignalType::Real.c_type(), "double");
    }

    #[test]
    fn test_node_validation() {
        let clk = Clock::new(10).unwrap();
        let mut node = LustreNode::new("test", clk);
        let errors = node.validate();
        assert!(errors.iter().any(|e| e.contains("at least one input")));

        node.add_input(Signal::new("x", SignalType::Int));
        node.add_output(Signal::new("y", SignalType::Int));
        assert!(node.validate().is_empty());

        // Duplicate name
        node.add_input(Signal::new("y", SignalType::Bool));
        let errors = node.validate();
        assert!(errors.iter().any(|e| e.contains("Duplicate")));
    }

    #[test]
    fn test_safety_standard_parsing() {
        assert_eq!("DO-178C".parse::<SafetyStandard>().unwrap(), SafetyStandard::Do178c);
        assert_eq!("IEC-61508".parse::<SafetyStandard>().unwrap(), SafetyStandard::Iec61508);
        assert_eq!("ISO-26262".parse::<SafetyStandard>().unwrap(), SafetyStandard::Iso26262);
    }

    #[test]
    fn test_embedded_target_parsing() {
        assert_eq!("arm-cortex-m".parse::<EmbeddedTarget>().unwrap(), EmbeddedTarget::ArmCortexM);
        assert_eq!("riscv".parse::<EmbeddedTarget>().unwrap(), EmbeddedTarget::RiscV);
        assert_eq!("x86".parse::<EmbeddedTarget>().unwrap(), EmbeddedTarget::X86);
    }

    #[test]
    fn test_wcet_deadline() {
        let w = Wcet::new("node_a", 800, 1000, true);
        assert!(w.meets_deadline());
        assert_eq!(w.slack_us(), 200);
        assert!((w.utilisation() - 0.8).abs() < 0.001);

        let w_fail = Wcet::new("node_b", 1200, 1000, true);
        assert!(!w_fail.meets_deadline());
        assert_eq!(w_fail.slack_us(), -200);
    }

    #[test]
    fn test_wcet_safety_standard_compliance() {
        // 70% utilisation => 30% margin => passes all standards
        let w = Wcet::new("ctrl", 700, 1000, true);
        assert!(w.satisfies_standard(&SafetyStandard::Iso26262));  // needs 20%
        assert!(w.satisfies_standard(&SafetyStandard::Iec61508));  // needs 15%
        assert!(w.satisfies_standard(&SafetyStandard::Do178c));    // needs 10%

        // 95% utilisation => 5% margin => fails all
        let w_tight = Wcet::new("ctrl", 950, 1000, true);
        assert!(!w_tight.satisfies_standard(&SafetyStandard::Do178c));
        assert!(!w_tight.satisfies_standard(&SafetyStandard::Iec61508));
        assert!(!w_tight.satisfies_standard(&SafetyStandard::Iso26262));
    }

    #[test]
    fn test_temporal_operator_display() {
        assert_eq!(format!("{}", TemporalOperator::Pre), "pre");
        assert_eq!(
            format!("{}", TemporalOperator::Fby { init_expr: "0".to_string() }),
            "0 fby"
        );
        assert_eq!(
            format!("{}", TemporalOperator::When { clock_signal: "clk_10hz".to_string() }),
            "when clk_10hz"
        );
        assert_eq!(
            format!("{}", TemporalOperator::Merge { clock_signal: "sel".to_string() }),
            "merge(sel)"
        );
    }
}
