<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
# TOPOLOGY.md — lustreiser

## Purpose

lustreiser generates verified real-time embedded code via Lustre. Lustre (Caspi and Halbwachs, Grenoble) is a synchronous dataflow language used in safety-critical domains including avionics (SCADE), nuclear control, and automotive systems. lustreiser reads control logic descriptions from a `lustreiser.toml` manifest and generates deterministic, bounded-execution-time C code via Lustre intermediate representation. It targets embedded systems engineers who need provably correct, race-free real-time control logic without writing Lustre directly.

## Module Map

```
lustreiser/
├── src/
│   ├── main.rs                    # CLI entry point (clap): init, validate, generate, build, run, info
│   ├── lib.rs                     # Library API
│   ├── manifest/mod.rs            # lustreiser.toml parser
│   ├── codegen/mod.rs             # Lustre (.lus) and C code generation
│   └── abi/                       # Idris2 ABI bridge stubs
├── examples/                      # Worked examples
├── verification/                  # Proof harnesses
├── container/                     # Stapeln container ecosystem
└── .machine_readable/             # A2ML metadata
```

## Data Flow

```
lustreiser.toml manifest
        │
   ┌────▼────┐
   │ Manifest │  parse + validate control logic node definitions
   │  Parser  │
   └────┬────┘
        │  validated synchronous dataflow config
   ┌────▼────┐
   │ Analyser │  check clock consistency, bounded execution constraints
   └────┬────┘
        │  intermediate representation
   ┌────▼────┐
   │ Codegen  │  emit generated/lustreiser/ (.lus Lustre source + deterministic C)
   └────┬────┘
        │  Lustre + C artifacts
   ┌────▼────┐
   │  Lustre  │  synchronous compiler → bounded-time C for embedded target
   └─────────┘
```
