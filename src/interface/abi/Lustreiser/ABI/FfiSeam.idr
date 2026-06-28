-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Layer 4 — ABI<->FFI Seam Soundness Proof for Lustreiser
|||
||| The structural gate (scripts/abi-ffi-gate.py) checks that the Idris2
||| `Result` enum and the Zig FFI enum agree by name and value. This module
||| supplies the *proof-side* guarantee that the encoding itself is SOUND:
|||
|||   (a) `resultToInt` is INJECTIVE — distinct ABI outcomes never collide on
|||       the wire (no two `Result` values map to the same C integer).
|||   (b) A decoder `intToResult : Bits32 -> Maybe Result` round-trips every
|||       `Result` faithfully (`resultRoundTrip`), proving the encoding is
|||       lossless; injectivity is then DERIVED from the round-trip.
|||
||| Together these seal the seam: the C integer returned by the Zig FFI
||| faithfully and unambiguously reconstructs the ABI `Result` it came from.
|||
||| Lustreiser defines exactly one FFI result-code encoder (`resultToInt`);
||| there is no `ProofStatus`/`statusToInt` (or other FFI enum encoder), so
||| clause (c) is vacuous here.

module Lustreiser.ABI.FfiSeam

import Lustreiser.ABI.Types

%default total

--------------------------------------------------------------------------------
-- Local lemma: Just is injective
--------------------------------------------------------------------------------

||| `Just` is injective. Defined locally (Idris2 0.7.0 has no `justInjective`
||| in scope here). The implicit equands are erased to avoid auto-binding a
||| free lowercase name with a warning.
justInj : {0 x, y : t} -> Just x = Just y -> x = y
justInj Refl = Refl

--------------------------------------------------------------------------------
-- (b) Faithful decoder and round-trip
--------------------------------------------------------------------------------

||| Decode a C integer back into a `Result`. Built with boolean `==` on
||| concrete `Bits32` literals, which reduces definitionally on each constant,
||| so the round-trip `Refl`s below check.
public export
intToResult : Bits32 -> Maybe Result
intToResult x =
  if x == 0 then Just Ok
  else if x == 1 then Just Error
  else if x == 2 then Just InvalidParam
  else if x == 3 then Just OutOfMemory
  else if x == 4 then Just NullPointer
  else if x == 5 then Just DeadlineViolation
  else if x == 6 then Just ClockError
  else Nothing

||| Faithful (lossless) encoding: decoding the encoding of any `Result`
||| recovers exactly that `Result`. Each case reduces because `intToResult`
||| branches on concrete `Bits32` literals via boolean `==`.
public export
resultRoundTrip : (r : Result) -> intToResult (resultToInt r) = Just r
resultRoundTrip Ok = Refl
resultRoundTrip Error = Refl
resultRoundTrip InvalidParam = Refl
resultRoundTrip OutOfMemory = Refl
resultRoundTrip NullPointer = Refl
resultRoundTrip DeadlineViolation = Refl
resultRoundTrip ClockError = Refl

--------------------------------------------------------------------------------
-- (a) Injectivity of the encoding (derived from the round-trip)
--------------------------------------------------------------------------------

||| The encoding is unambiguous: if two `Result`s encode to the same C
||| integer, they are the same `Result`. Derived cleanly from the round-trip:
||| `intToResult` applied to both sides yields `Just a = Just b`, and
||| `justInj` strips the constructor.
public export
resultToIntInjective : (a, b : Result) ->
                       resultToInt a = resultToInt b -> a = b
resultToIntInjective a b prf =
  justInj $
    trans (sym (resultRoundTrip a)) $
      trans (cong intToResult prf) (resultRoundTrip b)

--------------------------------------------------------------------------------
-- Positive controls (concrete decodes, machine-checked = Refl)
--------------------------------------------------------------------------------

||| Decoding 0 yields `Ok`.
decodeOk : intToResult 0 = Just Ok
decodeOk = Refl

||| Decoding 6 yields `ClockError` (the largest code).
decodeClockError : intToResult 6 = Just ClockError
decodeClockError = Refl

||| An out-of-range code decodes to `Nothing`.
decodeUnknown : intToResult 7 = Nothing
decodeUnknown = Refl

--------------------------------------------------------------------------------
-- Negative / non-vacuity control (distinct codes are distinct on the wire)
--------------------------------------------------------------------------------

||| Two DISTINCT result codes map to DISTINCT C integers. This is the
||| non-vacuity witness: injectivity would be trivially true if every
||| `Result` collapsed to one integer. `resultToInt Ok` reduces to the
||| primitive `Bits32` literal 0 and `resultToInt Error` to 1; the coverage
||| checker discharges `Refl impossible` for the two distinct constants.
okNotError : Not (resultToInt Ok = resultToInt Error)
okNotError Refl impossible

||| A second distinct-code witness, away from the 0/1 boundary (5 vs 6).
deadlineNotClock : Not (resultToInt DeadlineViolation = resultToInt ClockError)
deadlineNotClock Refl impossible
