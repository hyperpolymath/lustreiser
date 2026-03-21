// Lustreiser FFI Build Configuration
//
// Builds the shared and static libraries for the Lustre compilation
// and timing analysis FFI. The output libraries (liblustreiser.so/.a)
// implement the C-ABI functions declared in src/interface/abi/Foreign.idr.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared library (.so, .dylib, .dll)
    // Used for dynamic linking with the Rust CLI and Idris2 runtime.
    const lib = b.addSharedLibrary(.{
        .name = "lustreiser",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set version (keep in sync with Cargo.toml and VERSION in main.zig)
    lib.version = .{ .major = 0, .minor = 1, .patch = 0 };

    // Static library (.a)
    // Preferred for embedded targets where dynamic linking is unavailable.
    const lib_static = b.addStaticLibrary(.{
        .name = "lustreiser",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install artifacts
    b.installArtifact(lib);
    b.installArtifact(lib_static);

    // Generate header file for C compatibility.
    // This header is consumed by the Lustre-generated C code.
    const header = b.addInstallHeader(
        b.path("include/lustreiser.h"),
        "lustreiser.h",
    );
    b.getInstallStep().dependOn(&header.step);

    // Unit tests (run tests embedded in src/main.zig)
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Integration tests (verify FFI matches Idris2 ABI declarations)
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    integration_tests.linkLibrary(lib);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run ABI integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Documentation
    const docs = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });

    const docs_step = b.step("docs", "Generate FFI documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // Benchmark (WCET analysis performance)
    const bench = b.addExecutable(.{
        .name = "lustreiser-bench",
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    bench.linkLibrary(lib);

    const run_bench = b.addRunArtifact(bench);

    const bench_step = b.step("bench", "Run WCET analysis benchmarks");
    bench_step.dependOn(&run_bench.step);
}
