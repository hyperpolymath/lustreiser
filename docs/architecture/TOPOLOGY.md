<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Topology: lustreiser

## Overview

Lustreiser generates formally verified real-time embedded code via Lustre, the
synchronous dataflow language. It analyses control logic, extracts dataflow
patterns, generates Lustre nodes with clock calculus, compiles to deterministic
C for embedded targets, and proves timing bounds via Idris2 dependent types.

## Module Map

```
lustreiser/
├── src/
│   ├── main.rs                          # CLI entry point (clap subcommands)
│   ├── lib.rs                           # Library API (load → validate → generate)
│   ├── manifest/
│   │   └── mod.rs                       # lustreiser.toml parser and validator
│   ├── codegen/
│   │   └── mod.rs                       # Lustre node generation and C compilation
│   ├── abi/
│   │   └── mod.rs                       # Rust-side ABI types (mirrors Idris2)
│   └── interface/                       # Verified Interface Seams
│       ├── abi/                          # Idris2 ABI — formal proofs
│       │   ├── Types.idr                # LustreNode, Clock, DataflowStream,
│       │   │                            # TemporalOperator, WCET, SafetyLevel
│       │   ├── Layout.idr               # StreamBuffer, NodeLayout, memory
│       │   │                            # budget proofs, C struct layouts
│       │   └── Foreign.idr              # FFI declarations — compilation,
│       │                                # WCET analysis, clock validation
│       ├── ffi/                          # Zig FFI — C-ABI bridge
│       │   ├── build.zig                # Build config (shared + static lib)
│       │   ├── src/main.zig             # Implementation of Foreign.idr decls
│       │   └── test/integration_test.zig # ABI compliance tests
│       └── generated/                   # Auto-generated C headers
│           └── abi/                     # (populated by codegen)
├── Cargo.toml                           # Rust dependencies
├── lustreiser.toml                      # User manifest (input)
└── generated/lustreiser/                # Generated output directory
    ├── *.lus                            # Generated Lustre source files
    └── *.c                              # Generated deterministic C code
```

## Data Flow

```
                    ┌──────────────────┐
                    │  lustreiser.toml │  User-authored manifest
                    │  (TOML)          │  describing control system
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Manifest Parser │  src/manifest/mod.rs
                    │  (Rust)          │  Parse and validate TOML
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Control Flow    │  Extract dataflow topology
                    │  Analysis        │  Build DAG of node deps
                    │  (Rust)          │  Identify temporal operators
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼────────┐    │    ┌─────────▼────────┐
     │  Clock Calculus  │    │    │  WCET Analysis   │
     │  Validation      │    │    │  (Zig FFI)       │
     │  (Zig FFI)       │    │    │                  │
     └────────┬────────┘    │    └─────────┬────────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
                    ┌────────▼─────────┐
                    │  Idris2 ABI      │  Formal timing proofs:
                    │  Proofs          │  WCET < clock period
                    │  (Idris2)        │  Clock calculus soundness
                    │                  │  Memory budget fits RAM
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Lustre Codegen  │  Generate .lus files
                    │  (Rust)          │  with clock annotations,
                    │                  │  pre/fby/when/merge
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Lustre → C      │  Compile .lus to
                    │  Compilation     │  deterministic C:
                    │  (Zig FFI)       │  no malloc, no recursion,
                    │                  │  static buffers only
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Embedded C      │  Output: certifiable C
                    │  Output          │  for DO-178C, IEC 61508,
                    │                  │  ISO 26262 targets
                    └──────────────────┘
```

## Key Types (Idris2 ABI)

| Type | Module | Purpose |
|------|--------|---------|
| `LustreNode` | Types.idr | A computation unit with I/O streams, clock, and WCET |
| `Clock` | Types.idr | Sampling rate (period + phase in microseconds) |
| `DataflowStream` | Types.idr | Typed stream sampled on a specific clock |
| `TemporalOperator` | Types.idr | Pre, Fby, When, Merge — state and clock operators |
| `WCET` | Types.idr | Proof that a node meets its timing deadline |
| `CompositionSafe` | Types.idr | Proof that composing two nodes preserves bounds |
| `SafetyLevel` | Types.idr | DAL_A, SIL_4, ASIL_D certification tags |
| `StreamBuffer` | Layout.idr | Memory layout for a stream's history buffer |
| `NodeLayout` | Layout.idr | Complete memory layout for a node's state |
| `FitsInRAM` | Layout.idr | Proof that all nodes fit in available static RAM |

## Zig FFI Functions

| Function | Purpose |
|----------|---------|
| `lustreiser_init` | Create compilation context (1kHz base clock default) |
| `lustreiser_free` | Destroy context and release resources |
| `lustreiser_compile_nodes` | Parse manifest, generate Lustre nodes |
| `lustreiser_lustre_to_c` | Compile .lus to deterministic C |
| `lustreiser_analyse_wcet` | Compute worst-case execution time (microseconds) |
| `lustreiser_verify_deadline` | Check WCET < clock period |
| `lustreiser_validate_clocks` | Verify clock calculus consistency |
| `lustreiser_get_clock_tree` | Serialise clock hierarchy |
| `lustreiser_calc_memory_budget` | Total static memory for all buffers |
| `lustreiser_check_memory_fit` | Verify budget fits in target RAM |

## Safety Standards Mapping

| Standard | Domain | Lustreiser Relevance |
|----------|--------|---------------------|
| DO-178C Level A | Avionics (catastrophic failure) | Flight control, autopilot, sensor fusion |
| IEC 61508 SIL 3/4 | Industrial (nuclear, chemical) | Reactor protection, trip systems |
| ISO 26262 ASIL D | Automotive (life-threatening) | Engine management, braking, steering |

## Dependencies

- **Rust** (cargo): CLI, manifest parsing, orchestration
- **Idris2**: Formal proofs of timing bounds and memory layout
- **Zig**: C-ABI bridge, embedded cross-compilation
- **Lustre**: Generated synchronous dataflow code (not a build dependency — generated)
