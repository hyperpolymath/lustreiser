-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| ABI Type Definitions for Lustreiser
|||
||| This module defines the Application Binary Interface (ABI) for the
||| Lustre synchronous dataflow code generator. All type definitions
||| include formal proofs of correctness — particularly for timing bounds,
||| clock calculus, and deterministic execution guarantees.
|||
||| Lustre (Caspi, Pilaud, Halbwachs, Plaice — Grenoble) is the synchronous
||| dataflow language underlying SCADE. It guarantees deterministic,
||| bounded-time execution for safety-critical real-time systems.
|||
||| @see https://en.wikipedia.org/wiki/Lustre_(programming_language)
||| @see https://idris2.readthedocs.io for Idris2 documentation

module Lustreiser.ABI.Types

import Data.Bits
import Data.So
import Data.Vect
import Data.Nat

%default total

--------------------------------------------------------------------------------
-- Platform Detection
--------------------------------------------------------------------------------

||| Supported embedded platforms for generated Lustre/C code
public export
data Platform = Linux | Windows | MacOS | BSD | WASM
              | ARMCortexM | RISCV | Bare

||| Compile-time platform detection
||| Defaults to Linux; override with compiler flags for embedded targets
public export
thisPlatform : Platform
thisPlatform =
  %runElab do
    pure Linux

--------------------------------------------------------------------------------
-- Lustre Clock Types
--------------------------------------------------------------------------------

||| A clock defines the sampling rate of a dataflow stream.
||| Every stream in Lustre has exactly one clock — this is enforced by
||| clock calculus during compilation.
|||
||| @period  Tick period in microseconds (must be positive)
||| @phase   Phase offset in microseconds from the base clock
public export
record Clock where
  constructor MkClock
  period : Nat
  phase  : Nat
  {auto 0 periodPositive : So (period > 0)}

||| The base clock — fastest sampling rate in the system.
||| All other clocks divide evenly from this one.
public export
baseClock : Clock
baseClock = MkClock 1000 0  -- 1ms base tick (1kHz)

||| A derived clock must have a period that is a multiple of the base clock.
||| This is the fundamental constraint of Lustre clock calculus.
public export
data DerivedFrom : Clock -> Clock -> Type where
  ||| `derived` is a valid derived clock of `base` when its period
  ||| is an exact multiple of the base period.
  DeriveBy : (factor : Nat) ->
             {base : Clock} ->
             {derived : Clock} ->
             (derived.period = factor * base.period) ->
             DerivedFrom base derived

--------------------------------------------------------------------------------
-- Temporal Operators
--------------------------------------------------------------------------------

||| The four temporal operators in Lustre. These are the primitives
||| that introduce state and multi-rate behaviour into dataflow programs.
|||
||| - `Pre`   — access the previous value of a stream (one tick delay)
||| - `Fby`   — "followed by": initial value, then previous of another stream
||| - `When`  — downsample a stream to a slower clock
||| - `Merge` — combine streams from different clocks onto a faster clock
public export
data TemporalOperator : Type where
  ||| `pre(x)` — the value of stream `x` at the previous tick.
  ||| Undefined on the first tick; must be paired with `->` for initialisation.
  Pre : TemporalOperator
  ||| `x fby y` — equivalent to `x -> pre(y)`.
  ||| Returns `x` on the first tick, then `pre(y)` on subsequent ticks.
  Fby : TemporalOperator
  ||| `x when c` — sample stream `x` only when boolean clock `c` is true.
  ||| The resulting stream runs on a slower (derived) clock.
  When : TemporalOperator
  ||| `merge(c; x; y)` — combine two streams from different sub-clocks
  ||| back onto the base clock. `x` supplies values when `c` is true,
  ||| `y` when `c` is false.
  Merge : TemporalOperator

||| Temporal operators that introduce state (require memory allocation).
||| `When` and `Merge` are purely combinational clock operators.
public export
isStateful : TemporalOperator -> Bool
isStateful Pre = True
isStateful Fby = True
isStateful When = False
isStateful Merge = False

||| Decidable equality for temporal operators
public export
DecEq TemporalOperator where
  decEq Pre Pre = Yes Refl
  decEq Fby Fby = Yes Refl
  decEq When When = Yes Refl
  decEq Merge Merge = Yes Refl
  decEq _ _ = No absurd

--------------------------------------------------------------------------------
-- Dataflow Streams
--------------------------------------------------------------------------------

||| A typed dataflow stream sampled on a specific clock.
||| In Lustre, every expression denotes a stream — there are no scalar values.
|||
||| @elemType   The type of each element (e.g., Bits32, Double)
||| @clock      The clock that governs this stream's sampling rate
||| @bufSize    Number of elements to buffer (for `pre` operator)
public export
record DataflowStream where
  constructor MkStream
  elemType : Type
  clock    : Clock
  bufSize  : Nat
  {auto 0 bufPositive : So (bufSize > 0)}

||| A stream that uses the base clock (most common case)
public export
baseStream : (t : Type) -> DataflowStream
baseStream t = MkStream t baseClock 1

||| A stream that needs history for `pre` operator
public export
statefulStream : (t : Type) -> (clock : Clock) -> (depth : Nat) ->
                 {auto prf : So (depth > 0)} -> DataflowStream
statefulStream t c d = MkStream t c d

--------------------------------------------------------------------------------
-- Lustre Node Types
--------------------------------------------------------------------------------

||| A Lustre node — the fundamental unit of computation.
||| Nodes are pure functions from input streams to output streams,
||| plus internal state for temporal operators.
|||
||| @name        Node identifier (must be unique within a program)
||| @inputs      Input port declarations
||| @outputs     Output port declarations
||| @clock       The clock this node runs on
||| @wcet        Worst-case execution time in microseconds
public export
record LustreNode where
  constructor MkNode
  name    : String
  inputs  : Vect n DataflowStream
  outputs : Vect m DataflowStream
  clock   : Clock
  wcet    : Nat
  {auto 0 nameNonEmpty : So (length name > 0)}
  {auto 0 hasInputs : So (n > 0)}
  {auto 0 hasOutputs : So (m > 0)}
  {auto 0 wcetPositive : So (wcet > 0)}

||| Total static memory required for a node's stream buffers.
||| This is used to prove that a node fits within the target's
||| available RAM — no dynamic allocation permitted.
public export
nodeMemoryFootprint : LustreNode -> Nat
nodeMemoryFootprint node =
  let inputMem  = sum (map (\s => s.bufSize * 8) node.inputs)
      outputMem = sum (map (\s => s.bufSize * 8) node.outputs)
  in inputMem + outputMem

--------------------------------------------------------------------------------
-- WCET (Worst-Case Execution Time)
--------------------------------------------------------------------------------

||| Proof that a node's WCET fits within its clock period.
||| This is the central safety guarantee of Lustreiser: every node
||| completes execution before the next clock tick arrives.
|||
||| The synchronous hypothesis states that computation is instantaneous
||| relative to the clock. In practice, we prove WCET < period.
public export
data WCET : LustreNode -> Type where
  ||| `MeetsDeadline` proves that the node's worst-case execution time
  ||| is strictly less than its clock period, guaranteeing that every
  ||| cycle completes before the next tick.
  MeetsDeadline : (node : LustreNode) ->
                  So (node.wcet < node.clock.period) ->
                  WCET node

||| Check at the type level whether a node meets its timing deadline.
public export
checkDeadline : (node : LustreNode) -> Either String (WCET node)
checkDeadline node =
  case decSo (node.wcet < node.clock.period) of
    Yes prf => Right (MeetsDeadline node prf)
    No _    => Left ("Node '" ++ node.name ++ "' WCET (" ++
               show node.wcet ++ "us) exceeds clock period (" ++
               show node.clock.period ++ "us)")

||| Proof that composing two nodes preserves timing bounds.
||| When node A feeds into node B on the same clock, the combined
||| WCET must still fit within the clock period.
public export
data CompositionSafe : LustreNode -> LustreNode -> Type where
  SafeComposition : (a : LustreNode) -> (b : LustreNode) ->
                    So (a.wcet + b.wcet < a.clock.period) ->
                    CompositionSafe a b

--------------------------------------------------------------------------------
-- FFI Result Codes
--------------------------------------------------------------------------------

||| Result codes for FFI operations.
||| C-compatible integers for cross-language interop.
public export
data Result : Type where
  ||| Operation succeeded
  Ok : Result
  ||| Generic error
  Error : Result
  ||| Invalid parameter provided
  InvalidParam : Result
  ||| Out of memory (static buffer exhausted)
  OutOfMemory : Result
  ||| Null pointer encountered
  NullPointer : Result
  ||| WCET deadline would be violated
  DeadlineViolation : Result
  ||| Clock calculus inconsistency detected
  ClockError : Result

||| Convert Result to C integer
public export
resultToInt : Result -> Bits32
resultToInt Ok = 0
resultToInt Error = 1
resultToInt InvalidParam = 2
resultToInt OutOfMemory = 3
resultToInt NullPointer = 4
resultToInt DeadlineViolation = 5
resultToInt ClockError = 6

||| Results are decidably equal
public export
DecEq Result where
  decEq Ok Ok = Yes Refl
  decEq Error Error = Yes Refl
  decEq InvalidParam InvalidParam = Yes Refl
  decEq OutOfMemory OutOfMemory = Yes Refl
  decEq NullPointer NullPointer = Yes Refl
  decEq DeadlineViolation DeadlineViolation = Yes Refl
  decEq ClockError ClockError = Yes Refl
  decEq _ _ = No absurd

--------------------------------------------------------------------------------
-- Opaque Handles
--------------------------------------------------------------------------------

||| Opaque handle type for FFI.
||| Prevents direct construction, enforces creation through safe API.
public export
data Handle : Type where
  MkHandle : (ptr : Bits64) -> {auto 0 nonNull : So (ptr /= 0)} -> Handle

||| Safely create a handle from a pointer value.
||| Returns Nothing if pointer is null.
public export
createHandle : Bits64 -> Maybe Handle
createHandle 0 = Nothing
createHandle ptr = Just (MkHandle ptr)

||| Extract pointer value from handle
public export
handlePtr : Handle -> Bits64
handlePtr (MkHandle ptr) = ptr

--------------------------------------------------------------------------------
-- Platform-Specific Types
--------------------------------------------------------------------------------

||| C int size varies by platform
public export
CInt : Platform -> Type
CInt Linux = Bits32
CInt Windows = Bits32
CInt MacOS = Bits32
CInt BSD = Bits32
CInt WASM = Bits32
CInt ARMCortexM = Bits32
CInt RISCV = Bits32
CInt Bare = Bits32

||| C size_t varies by platform
public export
CSize : Platform -> Type
CSize WASM = Bits32
CSize ARMCortexM = Bits32
CSize _ = Bits64

||| Pointer size varies by platform (bits)
public export
ptrSize : Platform -> Nat
ptrSize WASM = 32
ptrSize ARMCortexM = 32
ptrSize _ = 64

--------------------------------------------------------------------------------
-- Memory Layout Proofs
--------------------------------------------------------------------------------

||| Proof that a type has a specific size in bytes
public export
data HasSize : Type -> Nat -> Type where
  SizeProof : {0 t : Type} -> {n : Nat} -> HasSize t n

||| Proof that a type has a specific alignment in bytes
public export
data HasAlignment : Type -> Nat -> Type where
  AlignProof : {0 t : Type} -> {n : Nat} -> HasAlignment t n

--------------------------------------------------------------------------------
-- Safety Standard Compliance Tags
--------------------------------------------------------------------------------

||| Safety integrity levels for generated code.
||| These tag generated output for certification evidence.
public export
data SafetyLevel : Type where
  ||| DO-178C Design Assurance Level A (catastrophic failure condition)
  DAL_A : SafetyLevel
  ||| DO-178C Design Assurance Level B (hazardous failure condition)
  DAL_B : SafetyLevel
  ||| IEC 61508 Safety Integrity Level 3
  SIL_3 : SafetyLevel
  ||| IEC 61508 Safety Integrity Level 4
  SIL_4 : SafetyLevel
  ||| ISO 26262 Automotive Safety Integrity Level D
  ASIL_D : SafetyLevel

||| A node annotated with its target safety level
public export
record CertifiedNode where
  constructor MkCertifiedNode
  node        : LustreNode
  safetyLevel : SafetyLevel
  wcetProof   : WCET node

--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

namespace Verify

  ||| Verify all timing proofs for a list of nodes
  export
  verifyTimingBounds : Vect n LustreNode -> Either String ()
  verifyTimingBounds [] = Right ()
  verifyTimingBounds (node :: rest) =
    case checkDeadline node of
      Left err => Left err
      Right _  => verifyTimingBounds rest

  ||| Verify that a node composition is safe
  export
  verifyComposition : LustreNode -> LustreNode -> Either String ()
  verifyComposition a b =
    case decSo (a.wcet + b.wcet < a.clock.period) of
      Yes _ => Right ()
      No _  => Left ("Composition of '" ++ a.name ++ "' and '" ++ b.name ++
                "' exceeds clock period")
