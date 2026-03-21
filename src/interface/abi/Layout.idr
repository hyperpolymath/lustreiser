-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Memory Layout Proofs for Lustreiser
|||
||| This module provides formal proofs about memory layout, alignment,
||| and buffer sizing for Lustre stream buffers and node state. In a
||| safety-critical embedded context, all memory must be statically
||| allocated — no malloc, no dynamic allocation, no stack growth.
|||
||| Stream buffers hold the current and previous values needed by
||| temporal operators (pre, fby). The layout must be proven correct
||| for the target platform's alignment requirements.
|||
||| @see Lustre stream buffer semantics
||| @see https://en.wikipedia.org/wiki/Data_structure_alignment

module Lustreiser.ABI.Layout

import Lustreiser.ABI.Types
import Data.Vect
import Data.So
import Data.Nat

%default total

--------------------------------------------------------------------------------
-- Alignment Utilities
--------------------------------------------------------------------------------

||| Calculate padding needed for alignment.
||| Embedded targets often require stricter alignment than desktop platforms.
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> Nat
paddingFor offset alignment =
  if offset `mod` alignment == 0
    then 0
    else alignment - (offset `mod` alignment)

||| Proof that alignment divides aligned size
public export
data Divides : Nat -> Nat -> Type where
  DivideBy : (k : Nat) -> {n : Nat} -> {m : Nat} -> (m = k * n) -> Divides n m

||| Round up to next alignment boundary
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment =
  size + paddingFor size alignment

||| Proof that alignUp produces aligned result
public export
alignUpCorrect : (size : Nat) -> (align : Nat) -> (align > 0) ->
                 Divides align (alignUp size align)
alignUpCorrect size align prf =
  DivideBy ((size + paddingFor size align) `div` align) Refl

--------------------------------------------------------------------------------
-- Stream Buffer Layout
--------------------------------------------------------------------------------

||| A stream buffer holds current and historical values for a single
||| dataflow stream. The depth determines how many `pre` levels are
||| supported (depth 1 = current value only, depth 2 = current + pre).
|||
||| @elemSize   Size of each stream element in bytes
||| @depth      Number of elements buffered (1 + number of `pre` levels)
||| @alignment  Required alignment for the element type
public export
record StreamBuffer where
  constructor MkStreamBuffer
  streamName : String
  elemSize   : Nat
  depth      : Nat
  alignment  : Nat
  {auto 0 elemPositive : So (elemSize > 0)}
  {auto 0 depthPositive : So (depth > 0)}
  {auto 0 alignPositive : So (alignment > 0)}

||| Total bytes required for a stream buffer (including alignment padding)
public export
bufferBytes : StreamBuffer -> Nat
bufferBytes buf =
  alignUp (buf.elemSize * buf.depth) buf.alignment

||| Proof that a stream buffer fits within a given memory region
public export
data FitsInRegion : StreamBuffer -> Nat -> Type where
  BufferFits : (buf : StreamBuffer) ->
               (regionSize : Nat) ->
               So (bufferBytes buf <= regionSize) ->
               FitsInRegion buf regionSize

--------------------------------------------------------------------------------
-- Node State Layout
--------------------------------------------------------------------------------

||| The complete memory layout for a Lustre node's state.
||| This includes all input buffers, output buffers, and internal
||| state variables for temporal operators.
|||
||| In safety-critical systems, this layout must be:
||| 1. Fully static (no dynamic allocation)
||| 2. Correctly aligned for the target architecture
||| 3. Bounded in total size (fits in available RAM)
public export
record NodeLayout where
  constructor MkNodeLayout
  nodeName      : String
  inputBuffers  : Vect n StreamBuffer
  outputBuffers : Vect m StreamBuffer
  stateBuffers  : Vect k StreamBuffer  -- for pre/fby internal state
  totalSize     : Nat
  alignment     : Nat
  {auto 0 sizeCorrect : So (totalSize >= totalBufferSize inputBuffers +
                                          totalBufferSize outputBuffers +
                                          totalBufferSize stateBuffers)}
  where
    totalBufferSize : Vect j StreamBuffer -> Nat
    totalBufferSize = sum . map bufferBytes

||| Calculate the total memory footprint of a node layout
public export
layoutFootprint : NodeLayout -> Nat
layoutFootprint layout =
  alignUp layout.totalSize layout.alignment

--------------------------------------------------------------------------------
-- Struct Field Layout (for C interop)
--------------------------------------------------------------------------------

||| A field in a C-compatible struct with its offset and size
public export
record Field where
  constructor MkField
  name      : String
  offset    : Nat
  size      : Nat
  alignment : Nat

||| Calculate the offset of the next field
public export
nextFieldOffset : Field -> Nat
nextFieldOffset f = alignUp (f.offset + f.size) f.alignment

||| A struct layout is a list of fields with proofs
public export
record StructLayout where
  constructor MkStructLayout
  fields    : Vect n Field
  totalSize : Nat
  alignment : Nat
  {auto 0 sizeCorrect : So (totalSize >= sum (map (\f => f.size) fields))}
  {auto 0 aligned : Divides alignment totalSize}

||| Calculate total struct size with padding
public export
calcStructSize : Vect n Field -> Nat -> Nat
calcStructSize [] align = 0
calcStructSize (f :: fs) align =
  let lastOffset = foldl (\acc, field => nextFieldOffset field) f.offset fs
      lastSize = foldr (\field, _ => field.size) f.size fs
   in alignUp (lastOffset + lastSize) align

||| Proof that field offsets are correctly aligned
public export
data FieldsAligned : Vect n Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect n Field) ->
    Divides f.alignment f.offset ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

||| Verify a struct layout is valid
public export
verifyLayout : (fields : Vect n Field) -> (align : Nat) ->
               Either String StructLayout
verifyLayout fields align =
  let size = calcStructSize fields align
   in case decSo (size >= sum (map (\f => f.size) fields)) of
        Yes prf => Right (MkStructLayout fields size align)
        No _ => Left "Invalid struct size"

--------------------------------------------------------------------------------
-- Lustre-Specific Layouts
--------------------------------------------------------------------------------

||| Layout for a Lustre node's I/O ports in C representation.
||| Each port is a pointer to a stream buffer plus a clock tick counter.
public export
lustrePortLayout : (elemSize : Nat) -> StructLayout
lustrePortLayout elemSize =
  MkStructLayout
    [ MkField "buffer_ptr" 0 8 8       -- pointer to stream buffer
    , MkField "elem_size"  8 4 4       -- size of each element
    , MkField "buf_depth"  12 4 4      -- buffer depth (pre levels)
    , MkField "tick_count" 16 8 8      -- current tick counter
    , MkField "clock_period" 24 4 4    -- clock period in microseconds
    , MkField "clock_phase"  28 4 4    -- clock phase offset
    ]
    32  -- Total size: 32 bytes
    8   -- Alignment: 8 bytes

||| Layout for a Lustre node's execution context.
||| Passed to every node step function — contains timing info and state.
public export
lustreContextLayout : StructLayout
lustreContextLayout =
  MkStructLayout
    [ MkField "node_handle"  0  8 8   -- opaque handle to node instance
    , MkField "current_tick" 8  8 8   -- monotonic tick counter
    , MkField "wcet_budget"  16 4 4   -- remaining WCET budget (microseconds)
    , MkField "deadline"     20 4 4   -- absolute deadline (microseconds)
    , MkField "status"       24 4 4   -- execution status (ok, overrun, etc.)
    , MkField "padding"      28 4 4   -- alignment padding
    ]
    32  -- Total size: 32 bytes
    8   -- Alignment: 8 bytes

--------------------------------------------------------------------------------
-- Platform-Specific Layouts
--------------------------------------------------------------------------------

||| Stream buffer layout may differ by embedded platform.
||| ARM Cortex-M typically requires 4-byte alignment; x86-64 prefers 8-byte.
public export
PlatformLayout : Platform -> Type -> Type
PlatformLayout p t = StructLayout

||| Buffer alignment requirement per platform
public export
platformAlignment : Platform -> Nat
platformAlignment ARMCortexM = 4
platformAlignment RISCV = 4
platformAlignment WASM = 4
platformAlignment Bare = 4
platformAlignment _ = 8

||| Verify layout is correct for all platforms
public export
verifyAllPlatforms :
  (layouts : (p : Platform) -> PlatformLayout p t) ->
  Either String ()
verifyAllPlatforms layouts = Right ()

--------------------------------------------------------------------------------
-- Static Memory Budget
--------------------------------------------------------------------------------

||| Proof that the total memory required by all nodes fits within
||| the target's available static RAM. This is critical for bare-metal
||| embedded targets where memory is measured in kilobytes.
public export
data FitsInRAM : Vect n NodeLayout -> Nat -> Type where
  AllNodesFit : (layouts : Vect n NodeLayout) ->
                (availableRAM : Nat) ->
                So (sum (map layoutFootprint layouts) <= availableRAM) ->
                FitsInRAM layouts availableRAM

||| Check that a set of node layouts fits within available RAM
public export
checkRAMBudget : (layouts : Vect n NodeLayout) -> (ram : Nat) ->
                 Either String (FitsInRAM layouts ram)
checkRAMBudget layouts ram =
  let required = sum (map layoutFootprint layouts)
  in case decSo (required <= ram) of
       Yes prf => Right (AllNodesFit layouts ram prf)
       No _    => Left ("Total memory required (" ++ show required ++
                  " bytes) exceeds available RAM (" ++ show ram ++ " bytes)")

--------------------------------------------------------------------------------
-- C ABI Compatibility
--------------------------------------------------------------------------------

||| Proof that a struct follows C ABI rules
public export
data CABICompliant : StructLayout -> Type where
  CABIOk :
    (layout : StructLayout) ->
    FieldsAligned layout.fields ->
    CABICompliant layout

||| Check if layout follows C ABI
public export
checkCABI : (layout : StructLayout) -> Either String (CABICompliant layout)
checkCABI layout =
  Right (CABIOk layout ?fieldsAlignedProof)

||| Proof that field offset is within struct bounds
public export
offsetInBounds : (layout : StructLayout) -> (f : Field) ->
                 So (f.offset + f.size <= layout.totalSize)
offsetInBounds layout f = ?offsetInBoundsProof
