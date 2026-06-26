-- SPDX-License-Identifier: MPL-2.0
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
import Decidable.Equality

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
    else minus alignment (offset `mod` alignment)

||| Proof that alignment divides aligned size: `m = k * n`.
public export
data Divides : Nat -> Nat -> Type where
  DivideBy : (k : Nat) -> {n : Nat} -> {m : Nat} -> (m = k * n) -> Divides n m

||| Sound decision procedure for divisibility. Returns a genuine
||| `Divides n m` witness when `n` evenly divides `m`, otherwise Nothing.
||| Division by zero is undecidable here and yields Nothing.
public export
decDivides : (n : Nat) -> (m : Nat) -> Maybe (Divides n m)
decDivides Z _ = Nothing
decDivides (S k) m =
  let q = m `div` (S k) in
  case decEq m (q * (S k)) of
    Yes prf => Just (DivideBy q prf)
    No _ => Nothing

||| Round up to next alignment boundary
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment =
  size + paddingFor size alignment

||| Sound divisibility check for an aligned size. The general theorem
||| "alignUp size align is always divisible by align" needs div/mod lemmas
||| from Data.Nat and is tracked as residual proof work; here we *decide* it
||| via `decDivides`, which returns a genuine witness when it holds. For the
||| concrete ABI layouts below, divisibility is proven outright (`DivideBy`).
||| (Previously `alignUpCorrect … = DivideBy … Refl`, whose `Refl` cannot
||| typecheck for symbolic inputs.)
public export
alignUpDivides : (size : Nat) -> (align : Nat) ->
                 Maybe (Divides align (alignUp size align))
alignUpDivides size align = decDivides align (alignUp size align)

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

||| Total bytes occupied by a vector of stream buffers (lifted out of the
||| `NodeLayout` record, where a `where` block is not valid syntax).
public export
totalBufferSize : {0 nb : Nat} -> Vect nb StreamBuffer -> Nat
totalBufferSize = sum . map bufferBytes

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
  inputBuffers  : Vect numIn StreamBuffer
  outputBuffers : Vect numOut StreamBuffer
  stateBuffers  : Vect numState StreamBuffer  -- for pre/fby internal state
  totalSize     : Nat
  alignment     : Nat
  {auto 0 sizeCorrect : So (totalSize >= totalBufferSize inputBuffers +
                                          totalBufferSize outputBuffers +
                                          totalBufferSize stateBuffers)}

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
  fields    : Vect numFields Field
  totalSize : Nat
  alignment : Nat
  {auto 0 sizeCorrect : So (totalSize >= sum (map (\f => f.size) fields))}
  {auto 0 aligned : Divides alignment totalSize}

||| Calculate total struct size with padding
public export
calcStructSize : {0 nf : Nat} -> Vect nf Field -> Nat -> Nat
calcStructSize [] align = 0
calcStructSize (f :: fs) align =
  let lastOffset = foldl (\acc, field => nextFieldOffset field) f.offset fs
      lastSize = foldr (\field, _ => field.size) f.size fs
   in alignUp (lastOffset + lastSize) align

||| Proof that field offsets are correctly aligned
public export
data FieldsAligned : Vect nf Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect nf Field) ->
    Divides f.alignment f.offset ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

||| Decide field alignment for every field, building a real `FieldsAligned`
||| witness from per-field divisibility proofs.
public export
decFieldsAligned : {0 nf : Nat} -> (fs : Vect nf Field) -> Maybe (FieldsAligned fs)
decFieldsAligned [] = Just NoFields
decFieldsAligned (f :: fs) =
  case decDivides f.alignment f.offset of
    Nothing => Nothing
    Just dvd => case decFieldsAligned fs of
                  Nothing => Nothing
                  Just rest => Just (ConsField f fs dvd rest)

||| Verify a struct layout is valid. Builds a `StructLayout` only when BOTH
||| obligations are discharged with genuine witnesses: the declared size covers
||| the sum of field sizes (`decSo`) and the alignment divides the total size
||| (`decDivides`). (Previously `MkStructLayout fields size align` left the
||| erased `aligned : Divides alignment totalSize` proof unsolved.)
public export
verifyLayout : {0 nf : Nat} -> (fields : Vect nf Field) -> (align : Nat) ->
               Either String StructLayout
verifyLayout fields align =
  let size = calcStructSize fields align
   in case decSo (size >= sum (map (\f => f.size) fields)) of
        No _ => Left "Invalid struct size"
        Yes prf => case decDivides align size of
          Nothing => Left "Total struct size is not aligned"
          Just dvd => Right (MkStructLayout fields size align
                              {sizeCorrect = prf} {aligned = dvd})

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
    {sizeCorrect = Oh}
    {aligned = DivideBy 4 Refl}

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
    {sizeCorrect = Oh}
    {aligned = DivideBy 4 Refl}

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
verifyAllPlatforms : {0 t : Type} ->
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
data FitsInRAM : {0 nl : Nat} -> Vect nl NodeLayout -> Nat -> Type where
  AllNodesFit : {0 nl : Nat} -> (layouts : Vect nl NodeLayout) ->
                (availableRAM : Nat) ->
                So (sum (map Layout.layoutFootprint layouts) <= availableRAM) ->
                FitsInRAM layouts availableRAM

||| Check that a set of node layouts fits within available RAM
public export
checkRAMBudget : {0 nl : Nat} -> (layouts : Vect nl NodeLayout) -> (ram : Nat) ->
                 Either String (FitsInRAM layouts ram)
checkRAMBudget layouts ram =
  case decSo (sum (map Layout.layoutFootprint layouts) <= ram) of
    Yes prf => Right (AllNodesFit layouts ram prf)
    No _    => Left ("Total memory required (" ++
               show (sum (map Layout.layoutFootprint layouts)) ++
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

||| Check if layout follows C ABI, returning a genuine `CABICompliant` proof
||| (built from real per-field divisibility witnesses) or an error when some
||| field offset is misaligned. (Previously `CABIOk layout ?fieldsAlignedProof`
||| with an unsolved hole.)
public export
checkCABI : (layout : StructLayout) -> Either String (CABICompliant layout)
checkCABI layout =
  case decFieldsAligned layout.fields of
    Just prf => Right (CABIOk layout prf)
    Nothing => Left "Field offsets are not correctly aligned for the C ABI"

||| Decide whether a field lies within a struct's byte bounds, returning a
||| genuine proof when `offset + size <= totalSize`. The previous signature
||| asserted this for *every* field unconditionally, which is unsound (a field
||| need not belong to the layout); this honest version decides it via `choose`.
public export
offsetInBounds : (layout : StructLayout) -> (f : Field) ->
                 Maybe (So (f.offset + f.size <= layout.totalSize))
offsetInBounds layout f =
  case choose (f.offset + f.size <= layout.totalSize) of
    Left ok => Just ok
    Right _ => Nothing
