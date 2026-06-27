-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Deeper structural invariants for Lustreiser (raises the Idris2 ABI to
||| Layer 3). This module builds DIRECTLY on the Layer-2 `Semantics` model
||| (same `Input`, `CounterNode`, `satInc`, `step`, `run`) — it does NOT
||| redefine the datatypes — and proves a genuinely different, deeper class
||| of property than Layer 2.
|||
||| Layer 2 proved (a) the per-tick / whole-run safety BOUND and (b)
||| determinism only at `cong` level ("equal inputs give equal outputs").
||| Both are shallow with respect to the *structure* of `run`: (b) holds of
||| any function and says nothing about how `run` decomposes over its stream.
|||
||| Layer 3 proves the ALGEBRAIC LAW that actually characterises a synchronous
||| node as a deterministic, replayable state machine — that `run` is a left
||| monoid action of the input stream on the node state:
|||
|||   FLAGSHIP THEOREM (composition / fold-fusion):
|||       run (xs ++ ys) c = run ys (run xs c)
|||
|||   proved by genuine structural INDUCTION over the prefix (not `cong`).
|||
||| From it follow the deeper operational corollaries (run-splitting; any run
||| ending in `Reset` clears the state). Independently, this module proves a
||| second, orthogonal transition-soundness theorem absent from Layer 2:
||| MONOTONICITY of the saturating successor in its counter argument
||| (`m <= n  =>  satInc cap m <= satInc cap n`) — the order-preservation
||| property that licenses interval / abstract-interpretation reasoning over
||| the node. A natural decision (`decEqInput`), positive controls, and a
||| non-vacuity (`Not (...)`) negative control are all machine-checked.
module Lustreiser.ABI.Invariants

import Data.Nat
import Decidable.Equality

import Lustreiser.ABI.Semantics

%default total

--------------------------------------------------------------------------------
-- A natural decision the Layer-2 model lacked: decidable equality of Input
--------------------------------------------------------------------------------

||| `Tick` is not `Reset`. Top-level `impossible` clause (Idris2 0.7.0 idiom;
||| no nested case-of-impossible).
export
tickNotReset : Tick = Reset -> Void
tickNotReset Refl impossible

||| Sound + complete decision procedure for input equality. `Yes` carries a
||| real `Refl`; each `No` carries a genuine refutation. This is exactly the
||| boolean clock test the per-tick semantics branches on.
public export
decEqInput : (i, j : Input) -> Dec (i = j)
decEqInput Tick  Tick  = Yes Refl
decEqInput Reset Reset = Yes Refl
decEqInput Tick  Reset = No tickNotReset
decEqInput Reset Tick  = No (\eq => tickNotReset (sym eq))

--------------------------------------------------------------------------------
-- FLAGSHIP THEOREM: `run` is a left action of (List Input) on CounterNode
--------------------------------------------------------------------------------

||| COMPOSITION / FOLD-FUSION (the Layer-3 flagship law).
|||
||| Running the concatenation `xs ++ ys` from state `c` equals running `ys`
||| from the state reached after running `xs`. This makes `run` a monoid
||| action of the free monoid of input streams on node state — the precise
||| algebraic content of "a synchronous node is a deterministic, replayable
||| state machine".
|||
||| Proved by genuine INDUCTION over the prefix `xs`: the cons step is closed
||| by the inductive hypothesis applied to `step x c` (NOT by `cong` over
||| `run`), so this is a real structural proof, deeper than Layer 2's `cong`.
public export
runAppend : (xs, ys : List Input) -> (c : CounterNode) ->
            run (xs ++ ys) c = run ys (run xs c)
runAppend []        ys c = Refl
runAppend (x :: xs) ys c = runAppend xs ys (step x c)

--------------------------------------------------------------------------------
-- Operational corollaries of the action law
--------------------------------------------------------------------------------

||| Single-tick decomposition: running `i :: is` is running `is` after the
||| one-tick transition. The basic operational unfold (holds definitionally).
public export
runConsSplit : (i : Input) -> (is : List Input) -> (c : CounterNode) ->
               run (i :: is) c = run is (step i c)
runConsSplit i is c = Refl

||| `run [Reset] c` clears the state to 0 (preserving the static cap), for any
||| node. A direct reading of the reset transition; reused below.
public export
runResetClears : (c : CounterNode) -> state (run [Reset] c) = 0
runResetClears (MkCounter _ _) = Refl

||| TRANSITION SOUNDNESS via the flagship law: ANY run whose suffix is a
||| single `Reset` ends in state 0, regardless of the prefix or starting
||| state. Proved THROUGH `runAppend` (replay the prefix to some state, then
||| apply the reset), so it genuinely consumes the Layer-3 theorem.
public export
runEndingInResetIsZero : (xs : List Input) -> (c : CounterNode) ->
                         state (run (xs ++ [Reset]) c) = 0
runEndingInResetIsZero xs c =
  rewrite runAppend xs [Reset] c in runResetClears (run xs c)

--------------------------------------------------------------------------------
-- ORTHOGONAL TRANSITION SOUNDNESS: monotonicity of the saturating successor
--------------------------------------------------------------------------------

||| MONOTONICITY of the saturating successor in its counter argument:
||| if `m <= n` then `satInc cap m <= satInc cap n`. This order-preservation
||| property is orthogonal to — and deeper than — the Layer-2 upper bound
||| (which only fixed the top of the range); it is what licenses interval /
||| abstract-interpretation reasoning about the node.
|||
||| Proof strategy: split on the SAME `isLTE (S m) cap` / `isLTE (S n) cap`
||| tests `satInc` itself uses, so every branch reduces. The four cases:
|||   * both unsaturated   : `S m <= S n` from `m <= n`.
|||   * m unsat, n sat     : `S m <= cap` directly from the m-side witness.
|||   * m sat, n unsat     : `cap <= S n`; from `n < cap` (n-side) we get
|||                          `S n <= cap`, but we need `cap <= S n`; instead
|||                          this case is impossible — `m <= n` with `n < cap`
|||                          forces `S m <= cap`, contradicting m-saturation.
|||   * both saturated     : `cap <= cap` reflexively.
public export
satIncMonotone : (cap : Nat) -> {m, n : Nat} -> LTE m n ->
                 LTE (satInc cap m) (satInc cap n)
satIncMonotone cap {m} {n} mLEn with (isLTE (S m) cap)
  satIncMonotone cap {m} {n} mLEn | Yes smLEcap with (isLTE (S n) cap)
    -- both unsaturated: satInc cap m = S m, satInc cap n = S n
    satIncMonotone cap {m} {n} mLEn | Yes _ | Yes _ = LTESucc mLEn
    -- m unsaturated, n saturated: satInc cap m = S m, satInc cap n = cap;
    -- the m-side witness `S m <= cap` is exactly the goal.
    satIncMonotone cap {m} {n} mLEn | Yes smLEcap | No _ = smLEcap
  satIncMonotone cap {m} {n} mLEn | No smGTcap with (isLTE (S n) cap)
    -- m saturated but n unsaturated is impossible: from m <= n we get
    -- S m <= S n; with `S n <= cap` (n-side) transitively `S m <= cap`,
    -- contradicting `not (S m <= cap)`.
    satIncMonotone cap {m} {n} mLEn | No smGTcap | Yes snLEcap =
      absurd (smGTcap (transitive (LTESucc mLEn) snLEcap))
    -- both saturated: satInc cap m = cap = satInc cap n.
    satIncMonotone cap {m} {n} mLEn | No _ | No _ = reflexive

||| Consequence at the node level: a `Tick` is monotone on state — if node
||| `c1` has no more count than `c2` (same cap), the same holds after a tick.
||| Connects the arithmetic monotonicity to the actual `step` transition.
public export
stepTickMonotone : (cap : Nat) -> {s1, s2 : Nat} -> LTE s1 s2 ->
                   LTE (state (step Tick (MkCounter cap s1)))
                       (state (step Tick (MkCounter cap s2)))
stepTickMonotone cap le = satIncMonotone cap le

--------------------------------------------------------------------------------
-- POSITIVE controls (inhabited witnesses / concrete instances)
--------------------------------------------------------------------------------

||| Composition law on a concrete split: replaying `[Tick,Tick]` then
||| `[Reset,Tick]` equals replaying the whole four-tick stream. Machine-
||| checked instance of the flagship theorem.
public export
appendWitness :
  run ([Tick,Tick] ++ [Reset,Tick]) (MkCounter 3 0)
    = run [Reset,Tick] (run [Tick,Tick] (MkCounter 3 0))
appendWitness = runAppend [Tick,Tick] [Reset,Tick] (MkCounter 3 0)

||| Reset-suffix soundness on a concrete prefix: a run ending in `Reset`
||| lands on state 0. Consumes `runEndingInResetIsZero` (hence `runAppend`).
public export
resetSuffixWitness :
  state (run ([Tick,Tick,Tick] ++ [Reset]) (MkCounter 3 0)) = 0
resetSuffixWitness = runEndingInResetIsZero [Tick,Tick,Tick] (MkCounter 3 0)

||| Monotonicity witness: `satInc 3 1 <= satInc 3 2` (i.e. `2 <= 3`).
||| Concrete instance of the order-preservation theorem.
public export
monotoneWitness : LTE (satInc 3 1) (satInc 3 2)
monotoneWitness = satIncMonotone 3 {m = 1} {n = 2} (LTESucc LTEZero)

--------------------------------------------------------------------------------
-- NEGATIVE / non-vacuity controls (the bad cases are genuinely refuted)
--------------------------------------------------------------------------------

||| Non-vacuity of the action law: the two sides do NOT collapse to a trivial
||| identity. Concretely, replaying the WHOLE stream from the start is NOT the
||| same as replaying only the suffix from the start (the prefix matters):
|||   run [Tick,Tick] (MkCounter 3 0)  /=  run [] (MkCounter 3 0).
||| Were `run` ignoring its prefix, the flagship law would be vacuous.
public export
prefixMatters :
  Not (run [Tick,Tick] (MkCounter 3 0) = run [] (MkCounter 3 0))
prefixMatters Refl impossible

||| Non-vacuity of `decEqInput`: `Tick` and `Reset` are genuinely distinct,
||| so the decision is not the constant `Yes`.
public export
inputsDistinct : Not (Tick = Reset)
inputsDistinct = tickNotReset

||| Non-vacuity of monotonicity: the order is NOT degenerate — `satInc 3 0`
||| is strictly below `satInc 3 1` (`1 <= 2` would be the loose bound, but the
||| sharp fact `satInc 3 0 = 1` and `satInc 3 1 = 2` is refuted-as-equal here:
||| they are not equal, so `satInc` is not constant).
public export
satIncNotConstant : Not (satInc 3 0 = satInc 3 1)
satIncNotConstant Refl impossible
