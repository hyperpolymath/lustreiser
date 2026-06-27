-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Flagship semantic proof for Lustreiser (raises the Idris2 ABI to Layer 2).
|||
||| Lustre is a synchronous dataflow language: a node is a deterministic
||| transition over discrete clock ticks. This module gives a faithful,
||| executable model of one such node — a *saturating bounded counter*,
||| the canonical pattern in real-time embedded code (watchdog ticks,
||| debounce counters, retry budgets) — and proves the two safety
||| properties that justify "formally verified real-time embedded code":
|||
|||   1. INVARIANT PRESERVATION (per tick): if the counter state satisfies
|||      `state <= cap` before a tick, it still satisfies `state <= cap`
|||      after the transition, for ANY input. Lifted to whole runs: every
|||      reachable state of the node respects the bound — no overflow.
|||
|||   2. DETERMINISM (the synchronous hypothesis): the node is a pure
|||      function of (state, input). Identical input streams from identical
|||      initial state produce identical output streams — bit-for-bit.
|||
||| The model is minimal but real: a true Lustre saturating counter,
||| with state, a reset input, and the `pre`/`fby`-style one-tick memory.
module Lustreiser.ABI.Semantics

import Data.Nat
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Faithful ADT model of a synchronous saturating-counter node
--------------------------------------------------------------------------------

||| The per-tick input to the node. On each clock tick the environment
||| either pulses `Tick` (advance the counter) or `Reset` (clear to 0).
||| This is the boolean clock input that Lustre `merge`/`when` would gate on.
public export
data Input = Tick | Reset

||| The node is parameterised by a static saturation bound `cap` — fixed at
||| compile time, exactly as a Lustre constant. State is the current count.
||| `cap` is part of the node identity (a field), not a free variable.
public export
record CounterNode where
  constructor MkCounter
  cap   : Nat
  state : Nat

||| Saturating successor: increments unless already at the cap.
||| Decided on the propositional `LTE (S n) cap` (i.e. `n < cap`) so the
||| bound proof can reuse exactly the witness this branch produces.
public export
satInc : (cap : Nat) -> (n : Nat) -> Nat
satInc cap n = case isLTE (S n) cap of
  Yes _ => S n
  No  _ => cap

||| One synchronous transition (the node's step / output function).
||| This is the ENTIRE behaviour of the node on a single clock tick.
public export
step : Input -> CounterNode -> CounterNode
step Tick  (MkCounter cap s) = MkCounter cap (satInc cap s)
step Reset (MkCounter cap s) = MkCounter cap 0

||| Run the node over a finite input stream (a list of ticks), threading
||| state left-to-right — this is the synchronous execution semantics.
public export
run : List Input -> CounterNode -> CounterNode
run []        c = c
run (i :: is) c = run is (step i c)

--------------------------------------------------------------------------------
-- PROPERTY 1: the per-tick safety invariant (counter never exceeds cap)
--------------------------------------------------------------------------------

||| The invariant: the node's state is within its static bound.
||| There is deliberately NO way to build `WithinBound` for an out-of-range
||| state other than via the genuine `LTE state cap` proof — the bad case
||| (state > cap) is simply not constructible.
public export
data WithinBound : CounterNode -> Type where
  IsWithin : {cap, s : Nat} -> LTE s cap -> WithinBound (MkCounter cap s)

--------------------------------------------------------------------------------
-- Lemmas (all genuine — no believe_me / postulate / assert)
--------------------------------------------------------------------------------

||| `satInc` never exceeds the cap, for any current value. Case split on the
||| same decidable `LTE (S n) cap` test that `satInc` itself uses, so each
||| branch reduces and is discharged with a real `LTE` proof.
public export
satIncBounded : (cap : Nat) -> (n : Nat) -> LTE (satInc cap n) cap
satIncBounded cap n with (isLTE (S n) cap)
  -- `S n <= cap`: `satInc = S n`, and that very proof is the bound.
  satIncBounded cap n | Yes prf = prf
  -- not `S n <= cap`: `satInc = cap`, and `cap <= cap` reflexively.
  satIncBounded cap n | No  _   = reflexive

||| INVARIANT PRESERVATION: if the state is within bound before a tick, it is
||| within bound after the tick — for EVERY input. This is the per-tick
||| safety theorem at the heart of the node.
public export
stepPreservesBound : (i : Input) -> (c : CounterNode) ->
                     WithinBound c -> WithinBound (step i c)
stepPreservesBound Tick  (MkCounter cap s) (IsWithin _) =
  IsWithin (satIncBounded cap s)
stepPreservesBound Reset (MkCounter cap s) (IsWithin _) =
  IsWithin LTEZero

||| INVARIANT for whole runs: if the initial state is within bound, then after
||| running ANY input stream the final state is still within bound. Proved by
||| induction over the stream, reusing the per-tick theorem at each step.
public export
runPreservesBound : (is : List Input) -> (c : CounterNode) ->
                    WithinBound c -> WithinBound (run is c)
runPreservesBound []        c w = w
runPreservesBound (i :: is) c w =
  runPreservesBound is (step i c) (stepPreservesBound i c w)

--------------------------------------------------------------------------------
-- Sound + complete decision procedure for the invariant
--------------------------------------------------------------------------------

||| Decide the invariant for a concrete node. Sound (Yes carries a real proof)
||| and complete (No carries a refutation of the bad case). Built on the
||| library `isLTE`, which is itself a genuine `Dec (LTE m n)`.
public export
decWithinBound : (c : CounterNode) -> Dec (WithinBound c)
decWithinBound (MkCounter cap s) = case isLTE s cap of
  Yes prf  => Yes (IsWithin prf)
  No  contra => No (\(IsWithin p) => contra p)

--------------------------------------------------------------------------------
-- PROPERTY 2: determinism (the synchronous hypothesis)
--------------------------------------------------------------------------------

||| DETERMINISM, one tick: the transition is a function, so equal inputs and
||| equal start states force equal results. This is the propositional content
||| of "the node is deterministic" — there is no nondeterministic branch.
public export
stepDeterministic : (i : Input) -> (c1, c2 : CounterNode) ->
                    c1 = c2 -> step i c1 = step i c2
stepDeterministic i c1 c2 eq = cong (step i) eq

||| DETERMINISM, whole run: identical input streams from identical initial
||| state yield identical final state — bit-for-bit. Proved by induction;
||| the engine of real-time reproducibility / replayability.
public export
runDeterministic : (is : List Input) -> (c1, c2 : CounterNode) ->
                   c1 = c2 -> run is c1 = run is c2
runDeterministic is c1 c2 eq = cong (run is) eq

--------------------------------------------------------------------------------
-- Certifier: maps a node + invariant proof to an ABI-level status
--------------------------------------------------------------------------------

||| ABI-facing verdict for a single node's bound check.
public export
data BoundStatus = BoundProven | BoundRefuted

||| Certify the bound invariant, returning a machine status. The decision is
||| the genuine `decWithinBound`, so `BoundProven` is never emitted without an
||| underlying `LTE` proof existing.
public export
certifyBound : (c : CounterNode) -> BoundStatus
certifyBound c = case decWithinBound c of
  Yes _ => BoundProven
  No  _ => BoundRefuted

||| SOUNDNESS of the certifier: if it says `BoundProven`, the invariant truly
||| holds. We recover the witness by re-running the same decision and matching
||| on its result — no axioms.
public export
certifyBoundSound : (c : CounterNode) -> certifyBound c = BoundProven ->
                    WithinBound c
certifyBoundSound c prf with (decWithinBound c)
  certifyBoundSound c prf       | Yes w = w
  certifyBoundSound c Refl      | No  _ impossible

--------------------------------------------------------------------------------
-- POSITIVE control: an explicit inhabited witness
--------------------------------------------------------------------------------

||| A concrete watchdog counter (cap = 3, state = 2) is within bound, and
||| stays within bound after a tick — a fully explicit, machine-checked
||| witness that the property is inhabited (non-trivial).
public export
safeWatchdogWithinBound : WithinBound (MkCounter 3 2)
safeWatchdogWithinBound = IsWithin (LTESucc (LTESucc LTEZero))

||| Running a real input stream from a within-bound start stays within bound.
||| (cap = 3, start = 0, stream = Tick,Tick,Tick,Tick,Reset,Tick) — the
||| saturation actually fires here, so this exercises the interesting path.
public export
safeRunWithinBound : WithinBound (run [Tick,Tick,Tick,Tick,Reset,Tick] (MkCounter 3 0))
safeRunWithinBound =
  runPreservesBound [Tick,Tick,Tick,Tick,Reset,Tick] (MkCounter 3 0) (IsWithin LTEZero)

||| Determinism positive control: the same stream from the same state lands on
||| the same concrete final node (checked by `Refl`, i.e. by reduction).
public export
safeRunDeterministic :
  run [Tick,Tick,Reset,Tick] (MkCounter 3 0)
    = run [Tick,Tick,Reset,Tick] (MkCounter 3 0)
safeRunDeterministic =
  runDeterministic [Tick,Tick,Reset,Tick] (MkCounter 3 0) (MkCounter 3 0) Refl

--------------------------------------------------------------------------------
-- NEGATIVE control: the bad case is genuinely refuted
--------------------------------------------------------------------------------

||| An out-of-range node (cap = 2, state = 5) does NOT satisfy the invariant.
||| Machine-checked: pattern-matching extracts the impossible `LTE 5 2` and
||| discharges it. This is what makes the property non-vacuous.
public export
overflowNotWithinBound : Not (WithinBound (MkCounter 2 5))
overflowNotWithinBound (IsWithin prf) = absurd prf
