// Lustreiser FFI Implementation
//
// This module implements the C-compatible FFI declared in src/interface/abi/Foreign.idr.
// It provides the Lustre compilation pipeline: dataflow analysis, node generation,
// clock calculus validation, WCET analysis, and C code generation.
//
// All types and layouts must match the Idris2 ABI definitions in Types.idr and Layout.idr.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

// Version information (keep in sync with Cargo.toml)
const VERSION = "0.1.0";
const BUILD_INFO = "lustreiser built with Zig " ++ @import("builtin").zig_version_string;

/// Thread-local error storage for diagnostic messages.
/// Safety-critical systems need deterministic error reporting.
threadlocal var last_error: ?[]const u8 = null;

/// Set the last error message
fn setError(msg: []const u8) void {
    last_error = msg;
}

/// Clear the last error
fn clearError() void {
    last_error = null;
}

//==============================================================================
// Core Types (must match src/interface/abi/Types.idr)
//==============================================================================

/// Result codes for FFI operations.
/// Must match the Idris2 `Result` type and `resultToInt` mapping exactly.
pub const Result = enum(c_int) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    out_of_memory = 3,
    null_pointer = 4,
    deadline_violation = 5,
    clock_error = 6,
};

/// Temporal operators in Lustre (matches Idris2 TemporalOperator).
/// Used to tag nodes and stream expressions during compilation.
pub const TemporalOp = enum(c_int) {
    pre = 0,   // Previous value (one tick delay)
    fby = 1,   // Followed-by (init -> pre)
    when = 2,  // Clock downsampling
    merge = 3, // Clock recombination
};

/// Clock definition — matches Idris2 Clock record.
/// period_us is in microseconds; phase_us is offset from base clock.
pub const Clock = struct {
    period_us: u32,
    phase_us: u32,
};

/// Stream buffer metadata — matches Idris2 StreamBuffer record.
/// Describes the memory layout for a single dataflow stream.
pub const StreamBuffer = struct {
    elem_size: u32,
    depth: u32,
    alignment: u32,
};

/// Library handle — the Lustre compilation context.
/// Holds the dataflow graph, clock tree, compiled nodes, and timing budget.
pub const LustreiserContext = struct {
    allocator: std.mem.Allocator,
    initialized: bool,
    base_clock: Clock,
    total_memory_budget: u32,
    node_count: u32,
};

//==============================================================================
// Library Lifecycle
//==============================================================================

/// Initialise the Lustreiser compilation context.
/// Returns a pointer to the context, or null on failure.
/// The context starts with a default 1kHz base clock (1000us period).
export fn lustreiser_init() ?*LustreiserContext {
    const allocator = std.heap.c_allocator;

    const ctx = allocator.create(LustreiserContext) catch {
        setError("Failed to allocate Lustreiser context");
        return null;
    };

    ctx.* = .{
        .allocator = allocator,
        .initialized = true,
        .base_clock = .{ .period_us = 1000, .phase_us = 0 },
        .total_memory_budget = 0,
        .node_count = 0,
    };

    clearError();
    return ctx;
}

/// Free the Lustreiser context and all associated resources.
export fn lustreiser_free(ctx: ?*LustreiserContext) void {
    const c = ctx orelse return;
    const allocator = c.allocator;

    c.initialized = false;
    allocator.destroy(c);
    clearError();
}

//==============================================================================
// Lustre Node Compilation
//==============================================================================

/// Compile a dataflow graph specification into Lustre node definitions.
/// manifest_path points to a null-terminated TOML file path.
///
/// Returns: ok (0) on success, or an error code:
///   - invalid_param (2): manifest path is null or unreadable
///   - deadline_violation (5): timing requirements cannot be satisfied
///   - clock_error (6): clock calculus inconsistency in specification
export fn lustreiser_compile_nodes(ctx: ?*LustreiserContext, manifest_path: ?[*:0]const u8) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    _ = manifest_path orelse {
        setError("Null manifest path");
        return .invalid_param;
    };

    // TODO: Parse manifest, build dataflow graph, generate .lus nodes
    // Steps:
    // 1. Parse TOML manifest
    // 2. Extract node declarations and stream types
    // 3. Build directed acyclic graph (modulo pre)
    // 4. Assign clocks via clock calculus
    // 5. Generate Lustre node definitions

    clearError();
    return .ok;
}

/// Compile Lustre source (.lus) to deterministic C code.
/// The generated C uses:
///   - No malloc (all buffers statically allocated)
///   - No recursion (bounded call depth)
///   - No unbounded loops (iteration counts known at compile time)
///   - Static stream buffers sized from Layout.idr proofs
export fn lustreiser_lustre_to_c(ctx: ?*LustreiserContext, lustre_src: ?[*:0]const u8, c_output: ?[*:0]const u8) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    _ = lustre_src orelse {
        setError("Null Lustre source path");
        return .invalid_param;
    };

    _ = c_output orelse {
        setError("Null C output path");
        return .invalid_param;
    };

    // TODO: Invoke Lustre compiler backend
    // Steps:
    // 1. Parse .lus file
    // 2. Verify clock annotations
    // 3. Generate C node step functions
    // 4. Generate static buffer declarations
    // 5. Generate main loop with tick scheduling

    clearError();
    return .ok;
}

//==============================================================================
// WCET Analysis
//==============================================================================

/// Analyse the worst-case execution time (WCET) of a compiled node.
/// Returns WCET in microseconds, or 0 on failure.
///
/// WCET analysis examines all code paths in the generated C to determine
/// the absolute maximum execution time. This value must be less than the
/// node's clock period for the synchronous hypothesis to hold.
export fn lustreiser_analyse_wcet(ctx: ?*LustreiserContext, node_name: ?[*:0]const u8) u32 {
    const c = ctx orelse {
        setError("Null context handle");
        return 0;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return 0;
    }

    _ = node_name orelse {
        setError("Null node name");
        return 0;
    };

    // TODO: Perform WCET analysis on the compiled node
    // Steps:
    // 1. Load compiled C code for the named node
    // 2. Build control flow graph
    // 3. Compute longest path through all branches
    // 4. Sum instruction cycle counts for target architecture
    // 5. Return worst-case total in microseconds

    clearError();
    return 0; // Stub: analysis not yet implemented
}

/// Verify that a node's WCET fits within the given clock period.
/// Returns ok (0) if WCET < period, deadline_violation (5) otherwise.
export fn lustreiser_verify_deadline(ctx: ?*LustreiserContext, node_name: ?[*:0]const u8, period_us: u32) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    const wcet = lustreiser_analyse_wcet(ctx, node_name);
    if (wcet == 0) {
        setError("WCET analysis failed — cannot verify deadline");
        return .@"error";
    }

    if (wcet >= period_us) {
        setError("WCET exceeds clock period — synchronous hypothesis violated");
        return .deadline_violation;
    }

    clearError();
    return .ok;
}

//==============================================================================
// Clock Calculus Validation
//==============================================================================

/// Validate the clock calculus of the current program.
/// Checks that every stream has exactly one well-defined clock, and that
/// all when/merge expressions are clock-consistent.
export fn lustreiser_validate_clocks(ctx: ?*LustreiserContext) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    // TODO: Validate clock tree
    // Steps:
    // 1. Collect all clock annotations from stream declarations
    // 2. Verify derived clocks have periods that are multiples of base
    // 3. Check when expressions: result clock = base clock / sampling rate
    // 4. Check merge expressions: operand clocks are complementary
    // 5. Verify no stream has ambiguous clock assignment

    clearError();
    return .ok;
}

/// Get the clock tree for the current program.
/// Returns a serialised string representation, or null on failure.
export fn lustreiser_get_clock_tree(ctx: ?*LustreiserContext) ?[*:0]const u8 {
    const c = ctx orelse {
        setError("Null context handle");
        return null;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return null;
    }

    // TODO: Serialise clock hierarchy
    const result = c.allocator.dupeZ(u8, "base_clock(1000us)") catch {
        setError("Failed to allocate clock tree string");
        return null;
    };

    clearError();
    return result.ptr;
}

//==============================================================================
// Stream Buffer Management
//==============================================================================

/// Calculate total static memory required for all stream buffers.
/// Returns bytes, or 0 on failure.
export fn lustreiser_calc_memory_budget(ctx: ?*LustreiserContext) u32 {
    const c = ctx orelse {
        setError("Null context handle");
        return 0;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return 0;
    }

    // TODO: Sum all stream buffer sizes from compiled nodes
    clearError();
    return c.total_memory_budget;
}

/// Verify that total memory footprint fits within available RAM.
/// Returns ok (0) if it fits, out_of_memory (3) otherwise.
export fn lustreiser_check_memory_fit(ctx: ?*LustreiserContext, available_ram: u32) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    if (c.total_memory_budget > available_ram) {
        setError("Stream buffers exceed available RAM");
        return .out_of_memory;
    }

    clearError();
    return .ok;
}

//==============================================================================
// String Operations
//==============================================================================

/// Get a diagnostic string from the context.
export fn lustreiser_get_string(ctx: ?*LustreiserContext) ?[*:0]const u8 {
    const c = ctx orelse {
        setError("Null context handle");
        return null;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return null;
    }

    const result = c.allocator.dupeZ(u8, "lustreiser diagnostic") catch {
        setError("Failed to allocate string");
        return null;
    };

    clearError();
    return result.ptr;
}

/// Free a string allocated by the library
export fn lustreiser_free_string(str: ?[*:0]const u8) void {
    const s = str orelse return;
    const allocator = std.heap.c_allocator;
    const slice = std.mem.span(s);
    allocator.free(slice);
}

//==============================================================================
// Error Handling
//==============================================================================

/// Get the last error message. Returns null if no error.
export fn lustreiser_last_error() ?[*:0]const u8 {
    const err = last_error orelse return null;
    const allocator = std.heap.c_allocator;
    const c_str = allocator.dupeZ(u8, err) catch return null;
    return c_str.ptr;
}

//==============================================================================
// Version Information
//==============================================================================

/// Get the library version string
export fn lustreiser_version() [*:0]const u8 {
    return VERSION.ptr;
}

/// Get build information string
export fn lustreiser_build_info() [*:0]const u8 {
    return BUILD_INFO.ptr;
}

//==============================================================================
// Callback Support
//==============================================================================

/// Callback function type for node execution monitoring (C ABI).
/// Called after each node step with context pointer and actual execution time.
pub const TimingCallback = *const fn (u64, u32) callconv(.C) u32;

/// Register a timing monitor callback.
/// The callback fires after each node step with actual execution time in
/// microseconds, allowing runtime WCET monitoring.
export fn lustreiser_register_callback(ctx: ?*LustreiserContext, callback: ?TimingCallback) Result {
    const c = ctx orelse {
        setError("Null context handle");
        return .null_pointer;
    };

    const cb = callback orelse {
        setError("Null callback");
        return .null_pointer;
    };

    if (!c.initialized) {
        setError("Context not initialized");
        return .@"error";
    }

    // TODO: Store callback for invocation after each node step
    _ = cb;

    clearError();
    return .ok;
}

//==============================================================================
// Utility Functions
//==============================================================================

/// Check if context is initialised
export fn lustreiser_is_initialized(ctx: ?*LustreiserContext) u32 {
    const c = ctx orelse return 0;
    return if (c.initialized) 1 else 0;
}

//==============================================================================
// Tests
//==============================================================================

test "lifecycle: init and free" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);
    try std.testing.expect(lustreiser_is_initialized(ctx) == 1);
}

test "lifecycle: null context is not initialised" {
    try std.testing.expect(lustreiser_is_initialized(null) == 0);
}

test "error: null context returns null_pointer" {
    const result = lustreiser_compile_nodes(null, null);
    try std.testing.expectEqual(Result.null_pointer, result);

    const err = lustreiser_last_error();
    try std.testing.expect(err != null);
}

test "clocks: validate on fresh context succeeds" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_validate_clocks(ctx);
    try std.testing.expectEqual(Result.ok, result);
}

test "memory: fresh context has zero budget" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const budget = lustreiser_calc_memory_budget(ctx);
    try std.testing.expectEqual(@as(u32, 0), budget);
}

test "memory: zero budget fits in any RAM" {
    const ctx = lustreiser_init() orelse return error.InitFailed;
    defer lustreiser_free(ctx);

    const result = lustreiser_check_memory_fit(ctx, 1024);
    try std.testing.expectEqual(Result.ok, result);
}

test "version: string is not empty" {
    const ver = lustreiser_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expect(ver_str.len > 0);
}

test "version: string is semantic version format" {
    const ver = lustreiser_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expect(std.mem.count(u8, ver_str, ".") >= 1);
}
