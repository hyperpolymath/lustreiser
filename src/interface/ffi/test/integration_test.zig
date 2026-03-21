// Lustreiser Integration Tests
//
// These tests verify that the Zig FFI correctly implements the Idris2 ABI
// declared in src/interface/abi/Foreign.idr. Each test exercises a specific
// FFI function and checks that return values, error codes, and state
// transitions match the formal ABI specification.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");
const testing = std.testing;

// Import FFI functions (linked against liblustreiser)
extern fn lustreiser_init() ?*opaque {};
extern fn lustreiser_free(?*opaque {}) void;
extern fn lustreiser_compile_nodes(?*opaque {}, ?[*:0]const u8) c_int;
extern fn lustreiser_lustre_to_c(?*opaque {}, ?[*:0]const u8, ?[*:0]const u8) c_int;
extern fn lustreiser_analyse_wcet(?*opaque {}, ?[*:0]const u8) u32;
extern fn lustreiser_verify_deadline(?*opaque {}, ?[*:0]const u8, u32) c_int;
extern fn lustreiser_validate_clocks(?*opaque {}) c_int;
extern fn lustreiser_get_clock_tree(?*opaque {}) ?[*:0]const u8;
extern fn lustreiser_calc_memory_budget(?*opaque {}) u32;
extern fn lustreiser_check_memory_fit(?*opaque {}, u32) c_int;
extern fn lustreiser_get_string(?*opaque {}) ?[*:0]const u8;
extern fn lustreiser_free_string(?[*:0]const u8) void;
extern fn lustreiser_last_error() ?[*:0]const u8;
extern fn lustreiser_version() [*:0]const u8;
extern fn lustreiser_build_info() [*:0]const u8;
extern fn lustreiser_is_initialized(?*opaque {}) u32;

//==============================================================================
// Lifecycle Tests
//==============================================================================

test "create and destroy context" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);
    try testing.expect(ctx != null);
}

test "context is initialised after init" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);
    try testing.expectEqual(@as(u32, 1), lustreiser_is_initialized(ctx));
}

test "null context is not initialised" {
    try testing.expectEqual(@as(u32, 0), lustreiser_is_initialized(null));
}

test "free null context is safe" {
    lustreiser_free(null); // Must not crash
}

//==============================================================================
// Node Compilation Tests
//==============================================================================

test "compile_nodes with null context returns null_pointer (4)" {
    const result = lustreiser_compile_nodes(null, null);
    try testing.expectEqual(@as(c_int, 4), result);
}

test "compile_nodes with null manifest returns invalid_param (2)" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_compile_nodes(ctx, null);
    try testing.expectEqual(@as(c_int, 2), result);
}

test "lustre_to_c with null context returns null_pointer (4)" {
    const result = lustreiser_lustre_to_c(null, null, null);
    try testing.expectEqual(@as(c_int, 4), result);
}

test "lustre_to_c with null source returns invalid_param (2)" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_lustre_to_c(ctx, null, "output.c");
    try testing.expectEqual(@as(c_int, 2), result);
}

//==============================================================================
// WCET Analysis Tests
//==============================================================================

test "analyse_wcet with null context returns 0" {
    const wcet = lustreiser_analyse_wcet(null, null);
    try testing.expectEqual(@as(u32, 0), wcet);
}

test "verify_deadline with null context returns null_pointer (4)" {
    const result = lustreiser_verify_deadline(null, null, 1000);
    try testing.expectEqual(@as(c_int, 4), result);
}

//==============================================================================
// Clock Calculus Tests
//==============================================================================

test "validate_clocks on fresh context succeeds (0)" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_validate_clocks(ctx);
    try testing.expectEqual(@as(c_int, 0), result);
}

test "validate_clocks with null context returns null_pointer (4)" {
    const result = lustreiser_validate_clocks(null);
    try testing.expectEqual(@as(c_int, 4), result);
}

test "get_clock_tree on fresh context returns non-null" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const tree = lustreiser_get_clock_tree(ctx);
    defer if (tree) |t| lustreiser_free_string(t);
    try testing.expect(tree != null);
}

//==============================================================================
// Memory Budget Tests
//==============================================================================

test "fresh context has zero memory budget" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const budget = lustreiser_calc_memory_budget(ctx);
    try testing.expectEqual(@as(u32, 0), budget);
}

test "zero budget fits in any RAM" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_check_memory_fit(ctx, 1024);
    try testing.expectEqual(@as(c_int, 0), result); // ok
}

test "memory fit with null context returns null_pointer (4)" {
    const result = lustreiser_check_memory_fit(null, 1024);
    try testing.expectEqual(@as(c_int, 4), result);
}

//==============================================================================
// String and Error Tests
//==============================================================================

test "get_string returns non-null for valid context" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const str = lustreiser_get_string(ctx);
    defer if (str) |s| lustreiser_free_string(s);
    try testing.expect(str != null);
}

test "get_string with null context returns null" {
    const str = lustreiser_get_string(null);
    try testing.expect(str == null);
}

test "last_error after null context operation" {
    _ = lustreiser_compile_nodes(null, null);
    const err = lustreiser_last_error();
    try testing.expect(err != null);

    if (err) |e| {
        const err_str = std.mem.span(e);
        try testing.expect(err_str.len > 0);
    }
}

//==============================================================================
// Version Tests
//==============================================================================

test "version string is not empty" {
    const ver = lustreiser_version();
    const ver_str = std.mem.span(ver);
    try testing.expect(ver_str.len > 0);
}

test "version string is semantic version format" {
    const ver = lustreiser_version();
    const ver_str = std.mem.span(ver);
    try testing.expect(std.mem.count(u8, ver_str, ".") >= 1);
}

test "build info string is not empty" {
    const info = lustreiser_build_info();
    const info_str = std.mem.span(info);
    try testing.expect(info_str.len > 0);
}

//==============================================================================
// Memory Safety Tests
//==============================================================================

test "multiple contexts are independent" {
    const ctx1 = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx1);

    const ctx2 = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx2);

    try testing.expect(ctx1 != ctx2);

    // Operations on ctx1 should not affect ctx2
    _ = lustreiser_validate_clocks(ctx1);
    _ = lustreiser_validate_clocks(ctx2);
}
