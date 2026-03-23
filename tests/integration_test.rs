// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Integration tests for lustreiser.
//
// These tests exercise the full pipeline: manifest parsing -> validation ->
// code generation, and verify that the generated Lustre and C artifacts
// are correct and complete.

use lustreiser::abi::{
    Clock, EmbeddedTarget, LustreNode, SafetyStandard, Signal, SignalType, TemporalOperator, Wcet,
};
use lustreiser::codegen;
use lustreiser::manifest::{self, Manifest};
use std::fs;
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Helper: write a manifest TOML and return the path
// ---------------------------------------------------------------------------

/// Write a TOML manifest to a temporary directory and return the path.
fn write_manifest(dir: &TempDir, content: &str) -> String {
    let path = dir.path().join("lustreiser.toml");
    fs::write(&path, content).expect("Failed to write manifest");
    path.to_string_lossy().to_string()
}

// ---------------------------------------------------------------------------
// Test 1: Full pipeline — flight controller (avionics, DO-178C)
// ---------------------------------------------------------------------------

#[test]
fn test_flight_controller_full_pipeline() {
    let dir = TempDir::new().unwrap();
    let manifest_path = write_manifest(
        &dir,
        r#"
[project]
name = "flight-controller"
version = "1.0.0"

[[nodes]]
name = "attitude_ctrl"
inputs = ["pitch:real", "roll:real", "yaw:real"]
outputs = ["elevator:real", "aileron:real", "rudder:real"]

[nodes.clock]
base-period-ms = 10

[[nodes]]
name = "nav_filter"
inputs = ["gps_lat:real@10", "gps_lon:real@10", "imu_accel:real"]
outputs = ["position_x:real", "position_y:real"]

[nodes.clock]
base-period-ms = 5

[target]
platform = "arm-cortex-m"
safety-standard = "DO-178C"

[timing]
deadline-us = 5000
wcet-analysis = true
"#,
    );

    // Load and validate.
    let m = manifest::load_manifest(&manifest_path).unwrap();
    manifest::validate(&m).unwrap();

    assert_eq!(m.project.name, "flight-controller");
    assert_eq!(m.nodes.len(), 2);
    assert_eq!(m.nodes[0].name, "attitude_ctrl");
    assert_eq!(m.nodes[1].name, "nav_filter");
    assert_eq!(m.target.platform, "arm-cortex-m");
    assert_eq!(m.target.safety_standard, "DO-178C");

    // Generate artifacts.
    let output_dir = dir.path().join("generated");
    codegen::generate_all(&m, output_dir.to_str().unwrap()).unwrap();

    // Verify Lustre files exist and contain expected content.
    let lus_attitude = fs::read_to_string(output_dir.join("attitude_ctrl.lus")).unwrap();
    assert!(lus_attitude.contains("node attitude_ctrl("));
    assert!(lus_attitude.contains("pitch: real"));
    assert!(lus_attitude.contains("elevator: real"));
    assert!(lus_attitude.contains("fby"));

    let lus_nav = fs::read_to_string(output_dir.join("nav_filter.lus")).unwrap();
    assert!(lus_nav.contains("node nav_filter("));
    assert!(lus_nav.contains("gps_lat"));
    // Nav filter is multi-rate (GPS at /10).
    assert!(lus_nav.contains("when") || lus_nav.contains("merge"));

    // Verify C files exist and contain expected content.
    let h_attitude = fs::read_to_string(output_dir.join("attitude_ctrl.h")).unwrap();
    assert!(h_attitude.contains("attitude_ctrl_state_t"));
    assert!(h_attitude.contains("attitude_ctrl_init"));
    assert!(h_attitude.contains("attitude_ctrl_step"));

    let c_attitude = fs::read_to_string(output_dir.join("attitude_ctrl.c")).unwrap();
    assert!(c_attitude.contains("#include \"attitude_ctrl.h\""));
    assert!(c_attitude.contains("void attitude_ctrl_init"));
    assert!(c_attitude.contains("void attitude_ctrl_step"));

    // Verify WCET report exists.
    let wcet_report = fs::read_to_string(output_dir.join("wcet_report.txt")).unwrap();
    assert!(wcet_report.contains("WCET Analysis Report"));
    assert!(wcet_report.contains("attitude_ctrl"));
    assert!(wcet_report.contains("nav_filter"));
    assert!(wcet_report.contains("DO-178C"));
}

// ---------------------------------------------------------------------------
// Test 2: Automotive controller (ISO 26262)
// ---------------------------------------------------------------------------

#[test]
fn test_automotive_abs_controller() {
    let dir = TempDir::new().unwrap();
    let manifest_path = write_manifest(
        &dir,
        r#"
[project]
name = "abs-controller"
version = "2.1.0"

[[nodes]]
name = "wheel_speed_monitor"
inputs = ["wheel_fl:int", "wheel_fr:int", "wheel_rl:int", "wheel_rr:int"]
outputs = ["slip_ratio:real", "brake_cmd:bool"]

[nodes.clock]
base-period-ms = 2

[target]
platform = "arm-cortex-m"
safety-standard = "ISO-26262"

[timing]
deadline-us = 1000
wcet-analysis = true
"#,
    );

    let m = manifest::load_manifest(&manifest_path).unwrap();
    manifest::validate(&m).unwrap();

    let output_dir = dir.path().join("out");
    codegen::generate_all(&m, output_dir.to_str().unwrap()).unwrap();

    // Check that the C code uses correct types for mixed int/real/bool signals.
    let header = fs::read_to_string(output_dir.join("wheel_speed_monitor.h")).unwrap();
    assert!(header.contains("int32_t wheel_fl"));
    assert!(header.contains("double slip_ratio"));
    assert!(header.contains("_Bool brake_cmd"));

    let source = fs::read_to_string(output_dir.join("wheel_speed_monitor.c")).unwrap();
    assert!(source.contains("wheel_speed_monitor_init"));
    assert!(source.contains("wheel_speed_monitor_step"));
}

// ---------------------------------------------------------------------------
// Test 3: RISC-V industrial controller (IEC 61508)
// ---------------------------------------------------------------------------

#[test]
fn test_riscv_industrial_controller() {
    let dir = TempDir::new().unwrap();
    let manifest_path = write_manifest(
        &dir,
        r#"
[project]
name = "plc-controller"

[[nodes]]
name = "safety_interlock"
inputs = ["emergency_stop:bool", "door_closed:bool", "pressure:real"]
outputs = ["allow_operation:bool"]

[nodes.clock]
base-period-ms = 1

[target]
platform = "riscv"
safety-standard = "IEC-61508"

[timing]
deadline-us = 500
wcet-analysis = true
"#,
    );

    let m = manifest::load_manifest(&manifest_path).unwrap();
    manifest::validate(&m).unwrap();

    assert_eq!(m.target.platform, "riscv");
    assert_eq!(m.project.version, "0.1.0"); // Default version.

    let output_dir = dir.path().join("out");
    codegen::generate_all(&m, output_dir.to_str().unwrap()).unwrap();

    let lus = fs::read_to_string(output_dir.join("safety_interlock.lus")).unwrap();
    assert!(lus.contains("emergency_stop: bool"));
    assert!(lus.contains("allow_operation: bool"));

    let header = fs::read_to_string(output_dir.join("safety_interlock.h")).unwrap();
    assert!(header.contains("_Bool emergency_stop"));
    assert!(header.contains("_Bool allow_operation"));
}

// ---------------------------------------------------------------------------
// Test 4: Manifest validation rejects bad input
// ---------------------------------------------------------------------------

#[test]
fn test_manifest_validation_errors() {
    let dir = TempDir::new().unwrap();

    // Missing nodes.
    let path = write_manifest(
        &dir,
        r#"
[project]
name = "bad"

[target]
platform = "x86"
safety-standard = "DO-178C"

[timing]
deadline-us = 1000
"#,
    );
    // This should fail to parse because [[nodes]] is required.
    let result = manifest::load_manifest(&path);
    assert!(result.is_err());

    // Invalid platform.
    let dir2 = TempDir::new().unwrap();
    let path2 = write_manifest(
        &dir2,
        r#"
[project]
name = "bad"

[[nodes]]
name = "n"
inputs = ["x:int"]
outputs = ["y:int"]

[nodes.clock]
base-period-ms = 10

[target]
platform = "powerpc"
safety-standard = "DO-178C"

[timing]
deadline-us = 1000
"#,
    );
    let m = manifest::load_manifest(&path2).unwrap();
    let err = manifest::validate(&m).unwrap_err();
    assert!(err.to_string().contains("not recognised"));
}

// ---------------------------------------------------------------------------
// Test 5: ABI types — round-trip and interop
// ---------------------------------------------------------------------------

#[test]
fn test_abi_types_round_trip() {
    // Build a LustreNode programmatically and verify it validates.
    let clk = Clock::new(10).unwrap();
    let mut node = LustreNode::new("pid_ctrl", clk);
    node.add_input(Signal::new("setpoint", SignalType::Real));
    node.add_input(Signal::new("measurement", SignalType::Real));
    node.add_output(Signal::new("command", SignalType::Real));
    node.add_operator(TemporalOperator::Fby {
        init_expr: "0.0".to_string(),
    });
    node.add_operator(TemporalOperator::Pre);

    let errors = node.validate();
    assert!(
        errors.is_empty(),
        "Unexpected validation errors: {:?}",
        errors
    );

    // Display format.
    let display = format!("{}", node);
    assert!(display.contains("pid_ctrl"));
    assert!(display.contains("setpoint"));
    assert!(display.contains("command"));

    // Safety standards.
    let do178c: SafetyStandard = "DO-178C".parse().unwrap();
    assert_eq!(do178c, SafetyStandard::Do178c);
    assert!(do178c.wcet_margin_percent() < 15.0);

    // Embedded targets.
    let arm: EmbeddedTarget = "arm-cortex-m".parse().unwrap();
    assert_eq!(arm.target_triple(), "arm-none-eabi");
    assert!(arm.compiler_flags().len() > 0);

    let riscv: EmbeddedTarget = "riscv".parse().unwrap();
    assert_eq!(riscv.target_triple(), "riscv32-unknown-elf");

    // WCET: 700/1000 = 70% utilisation => 30% margin, passes all standards.
    let wcet = Wcet::new("pid_ctrl", 700, 1000, true);
    assert!(wcet.meets_deadline());
    assert_eq!(wcet.slack_us(), 300);
    assert!(wcet.satisfies_standard(&SafetyStandard::Iso26262));
}

// ---------------------------------------------------------------------------
// Test 6: Multi-rate signal handling (when/merge operators)
// ---------------------------------------------------------------------------

#[test]
fn test_multi_rate_signal_handling() {
    let dir = TempDir::new().unwrap();
    let manifest_path = write_manifest(
        &dir,
        r#"
[project]
name = "sensor-fusion"
version = "0.3.0"

[[nodes]]
name = "fusion"
inputs = ["imu_accel:real", "gps_pos:real@20", "baro_alt:real@5"]
outputs = ["fused_pos:real", "fused_alt:real"]

[nodes.clock]
base-period-ms = 5

[target]
platform = "arm-cortex-m"
safety-standard = "DO-178C"

[timing]
deadline-us = 3000
wcet-analysis = true
"#,
    );

    let m = manifest::load_manifest(&manifest_path).unwrap();
    manifest::validate(&m).unwrap();

    let output_dir = dir.path().join("out");
    codegen::generate_all(&m, output_dir.to_str().unwrap()).unwrap();

    // The Lustre file should show multi-rate handling.
    let lus = fs::read_to_string(output_dir.join("fusion.lus")).unwrap();
    assert!(lus.contains("@/20"), "GPS should be annotated as rate /20");
    assert!(lus.contains("@/5"), "Baro should be annotated as rate /5");
    assert!(lus.contains("when"), "Multi-rate requires 'when' operator");
    assert!(
        lus.contains("merge"),
        "Multi-rate requires 'merge' operator"
    );

    // The C file should have tick-based rate division.
    let c_source = fs::read_to_string(output_dir.join("fusion.c")).unwrap();
    assert!(
        c_source.contains("tick_count"),
        "Multi-rate C needs tick counter"
    );
    assert!(c_source.contains("% 20"), "GPS rate division by 20");

    // The header should have the tick counter in the state struct.
    let header = fs::read_to_string(output_dir.join("fusion.h")).unwrap();
    assert!(header.contains("uint32_t tick_count"));
}

// ---------------------------------------------------------------------------
// Test 7: Init manifest creates valid template
// ---------------------------------------------------------------------------

#[test]
fn test_init_manifest_creates_valid_file() {
    let dir = TempDir::new().unwrap();
    let dir_path = dir.path().to_str().unwrap();

    manifest::init_manifest(dir_path).unwrap();

    // The created file should be parseable and valid.
    let manifest_path = dir.path().join("lustreiser.toml");
    assert!(manifest_path.exists());

    let m = manifest::load_manifest(manifest_path.to_str().unwrap()).unwrap();
    manifest::validate(&m).unwrap();
    assert_eq!(m.project.name, "my-controller");
    assert_eq!(m.nodes.len(), 1);
}

// ---------------------------------------------------------------------------
// Test 8: x86 target (simulation mode)
// ---------------------------------------------------------------------------

#[test]
fn test_x86_simulation_target() {
    let dir = TempDir::new().unwrap();
    let manifest_path = write_manifest(
        &dir,
        r#"
[project]
name = "sim-test"

[[nodes]]
name = "echo"
inputs = ["in_val:float"]
outputs = ["out_val:float"]

[nodes.clock]
base-period-ms = 100

[target]
platform = "x86"
safety-standard = "ISO-26262"

[timing]
deadline-us = 50000
wcet-analysis = false
"#,
    );

    let m = manifest::load_manifest(&manifest_path).unwrap();
    manifest::validate(&m).unwrap();

    let output_dir = dir.path().join("out");
    codegen::generate_all(&m, output_dir.to_str().unwrap()).unwrap();

    // Lustre file should exist.
    assert!(output_dir.join("echo.lus").exists());
    // C files should exist.
    assert!(output_dir.join("echo.h").exists());
    assert!(output_dir.join("echo.c").exists());
    // WCET report should NOT exist (wcet-analysis = false).
    assert!(!output_dir.join("wcet_report.txt").exists());

    // Verify float type mapping.
    let header = fs::read_to_string(output_dir.join("echo.h")).unwrap();
    assert!(
        header.contains("float in_val"),
        "float signal should map to C float"
    );
    assert!(header.contains("float out_val"));
}
