-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Machine-checked proofs over the lustreiser ABI.
|||
||| These are not runtime tests — they are propositional statements the Idris2
||| type checker must discharge at compile time. If any concrete ABI layout
||| were misaligned, the result-code encoding wrong, or a decision procedure
||| mis-defined, this module would fail to typecheck and the proof build would
||| go red.
|||
||| The C-ABI compliance witnesses are built directly from per-field
||| divisibility proofs (`DivideBy k Refl`, where `offset = k * alignment`).
||| Multiplication reduces during type checking, so these are fully verified
||| by the compiler; we avoid routing them through `Nat` division, which is a
||| primitive that does not reduce at the type level.

module Lustreiser.ABI.Proofs

import Lustreiser.ABI.Types
import Lustreiser.ABI.Layout
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- The concrete FFI struct layouts are provably C-ABI compliant.
--------------------------------------------------------------------------------

||| Every field offset in the Lustre port layout divides its alignment:
||| 0|8, 8|4, 12|4, 16|8, 24|4, 28|4. The fields are independent of the
||| element-size argument, so we instantiate it at 4 (a Bits32 element).
export
lustrePortCompliant : CABICompliant (Layout.lustrePortLayout 4)
lustrePortCompliant =
  CABIOk (lustrePortLayout 4)
    (ConsField _ _ (DivideBy 0 Refl)
    (ConsField _ _ (DivideBy 2 Refl)
    (ConsField _ _ (DivideBy 3 Refl)
    (ConsField _ _ (DivideBy 2 Refl)
    (ConsField _ _ (DivideBy 6 Refl)
    (ConsField _ _ (DivideBy 7 Refl)
     NoFields))))))

||| Every field offset in the Lustre execution-context layout is aligned:
||| 0|8, 8|8, 16|4, 20|4, 24|4, 28|4.
export
lustreContextCompliant : CABICompliant Layout.lustreContextLayout
lustreContextCompliant =
  CABIOk lustreContextLayout
    (ConsField _ _ (DivideBy 0 Refl)
    (ConsField _ _ (DivideBy 1 Refl)
    (ConsField _ _ (DivideBy 4 Refl)
    (ConsField _ _ (DivideBy 5 Refl)
    (ConsField _ _ (DivideBy 6 Refl)
    (ConsField _ _ (DivideBy 7 Refl)
     NoFields))))))

--------------------------------------------------------------------------------
-- Result-code round-trip: the encoding the Zig FFI depends on.
--------------------------------------------------------------------------------

||| `Ok` encodes to 0 — the success convention the C/Zig side relies on.
export
okIsZero : resultToInt Ok = 0
okIsZero = Refl

||| `DeadlineViolation` encodes to 5 — the WCET-overrun code.
export
deadlineViolationIsFive : resultToInt DeadlineViolation = 5
deadlineViolationIsFive = Refl

||| `ClockError` encodes to 6 — the clock-calculus inconsistency code.
export
clockErrorIsSix : resultToInt ClockError = 6
clockErrorIsSix = Refl

--------------------------------------------------------------------------------
-- Temporal-operator state classification is exactly the stateful pair.
--------------------------------------------------------------------------------

||| `pre` introduces state (needs a memory cell for the previous value).
export
preIsStateful : isStateful Pre = True
preIsStateful = Refl

||| `fby` introduces state (initial value, then previous).
export
fbyIsStateful : isStateful Fby = True
fbyIsStateful = Refl

||| `when` is purely combinational — a clock projection, no memory.
export
whenIsStateless : isStateful When = False
whenIsStateless = Refl

||| `merge` is purely combinational — recombines sub-clocks, no memory.
export
mergeIsStateless : isStateful Merge = False
mergeIsStateless = Refl
