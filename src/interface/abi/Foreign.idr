-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Foreign Function Interface Declarations for Lustreiser
|||
||| This module declares all C-compatible functions that will be
||| implemented in the Zig FFI layer. These functions provide:
|||
||| - Lustre node compilation (dataflow graph to .lus files)
||| - Lustre-to-C compilation (generating deterministic embedded C)
||| - WCET timing analysis and deadline verification
||| - Clock calculus validation
||| - Stream buffer management
|||
||| All functions are declared here with type signatures and safety proofs.
||| Implementations live in src/interface/ffi/src/main.zig.

module Lustreiser.ABI.Foreign

import Lustreiser.ABI.Types
import Lustreiser.ABI.Layout

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Initialise the Lustreiser library.
||| Returns a handle to the compilation context, or Nothing on failure.
||| The context holds the dataflow graph, clock tree, and timing budget.
export
%foreign "C:lustreiser_init, liblustreiser"
prim__init : PrimIO Bits64

||| Safe wrapper for library initialisation
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO prim__init
  pure (createHandle ptr)

||| Clean up library resources (deallocate compilation context)
export
%foreign "C:lustreiser_free, liblustreiser"
prim__free : Bits64 -> PrimIO ()

||| Safe wrapper for cleanup
export
free : Handle -> IO ()
free h = primIO (prim__free (handlePtr h))

--------------------------------------------------------------------------------
-- Lustre Node Compilation
--------------------------------------------------------------------------------

||| Compile a dataflow graph specification into Lustre node definitions.
||| Takes a manifest path (TOML) and generates .lus files.
|||
||| Returns Ok on success, or an error code if the specification is
||| invalid (e.g., cyclic dependencies without `pre`, missing clocks).
export
%foreign "C:lustreiser_compile_nodes, liblustreiser"
prim__compileNodes : Bits64 -> Bits64 -> PrimIO Bits32

||| Safe wrapper for Lustre node compilation.
||| Compiles the manifest at the given path into Lustre source files.
export
compileNodes : Handle -> (manifestPath : Bits64) -> IO (Either Result ())
compileNodes h path = do
  result <- primIO (prim__compileNodes (handlePtr h) path)
  pure $ case result of
    0 => Right ()
    1 => Left Error
    2 => Left InvalidParam
    5 => Left DeadlineViolation
    6 => Left ClockError
    _ => Left Error

||| Compile Lustre source (.lus) to deterministic C code.
||| The generated C uses no malloc, no recursion, no unbounded loops.
||| All buffers are statically allocated based on the stream layout.
export
%foreign "C:lustreiser_lustre_to_c, liblustreiser"
prim__lustreToC : Bits64 -> Bits64 -> Bits64 -> PrimIO Bits32

||| Safe wrapper for Lustre-to-C compilation
export
lustreToC : Handle -> (lustreSrc : Bits64) -> (cOutput : Bits64) ->
            IO (Either Result ())
lustreToC h src out = do
  result <- primIO (prim__lustreToC (handlePtr h) src out)
  pure $ case result of
    0 => Right ()
    n => Left Error

--------------------------------------------------------------------------------
-- WCET Analysis
--------------------------------------------------------------------------------

||| Analyse the worst-case execution time (WCET) of a compiled node.
||| Returns the WCET in microseconds, or 0 on failure.
|||
||| WCET analysis examines all code paths in the generated C to determine
||| the absolute maximum execution time. This value is compared against
||| the clock period to verify the synchronous hypothesis.
export
%foreign "C:lustreiser_analyse_wcet, liblustreiser"
prim__analyseWcet : Bits64 -> Bits64 -> PrimIO Bits32

||| Safe wrapper for WCET analysis.
||| Returns Right with WCET in microseconds, or Left with error.
export
analyseWcet : Handle -> (nodeName : Bits64) -> IO (Either Result Bits32)
analyseWcet h name = do
  result <- primIO (prim__analyseWcet (handlePtr h) name)
  pure $ case result of
    0 => Left Error  -- 0 means analysis failed
    n => Right n     -- WCET in microseconds

||| Verify that a node's WCET fits within its clock period.
||| This is the formal runtime check complementing the Idris2 proof.
export
%foreign "C:lustreiser_verify_deadline, liblustreiser"
prim__verifyDeadline : Bits64 -> Bits64 -> Bits32 -> PrimIO Bits32

||| Safe wrapper for deadline verification.
||| Returns Right () if deadline is met, Left DeadlineViolation otherwise.
export
verifyDeadline : Handle -> (nodeName : Bits64) -> (periodUs : Bits32) ->
                 IO (Either Result ())
verifyDeadline h name period = do
  result <- primIO (prim__verifyDeadline (handlePtr h) name period)
  pure $ case result of
    0 => Right ()
    5 => Left DeadlineViolation
    _ => Left Error

--------------------------------------------------------------------------------
-- Clock Calculus Validation
--------------------------------------------------------------------------------

||| Validate the clock calculus of a Lustre program.
||| Every stream must have exactly one well-defined clock. This function
||| checks that all `when`/`merge` expressions are clock-consistent.
export
%foreign "C:lustreiser_validate_clocks, liblustreiser"
prim__validateClocks : Bits64 -> PrimIO Bits32

||| Safe wrapper for clock validation
export
validateClocks : Handle -> IO (Either Result ())
validateClocks h = do
  result <- primIO (prim__validateClocks (handlePtr h))
  pure $ case result of
    0 => Right ()
    6 => Left ClockError
    _ => Left Error

||| Get the clock tree for the current program.
||| Returns a pointer to a serialised clock hierarchy, or null on failure.
export
%foreign "C:lustreiser_get_clock_tree, liblustreiser"
prim__getClockTree : Bits64 -> PrimIO Bits64

||| Retrieve the clock tree as a string representation
export
getClockTree : Handle -> IO (Maybe String)
getClockTree h = do
  ptr <- primIO (prim__getClockTree (handlePtr h))
  if ptr == 0
    then pure Nothing
    else pure (Just (prim__getString ptr))

--------------------------------------------------------------------------------
-- Stream Buffer Management
--------------------------------------------------------------------------------

||| Calculate the total static memory required for all stream buffers
||| in the compiled program. Returns bytes, or 0 on failure.
export
%foreign "C:lustreiser_calc_memory_budget, liblustreiser"
prim__calcMemoryBudget : Bits64 -> PrimIO Bits32

||| Safe wrapper for memory budget calculation
export
calcMemoryBudget : Handle -> IO (Either Result Bits32)
calcMemoryBudget h = do
  result <- primIO (prim__calcMemoryBudget (handlePtr h))
  pure $ case result of
    0 => Left Error
    n => Right n

||| Verify that the total memory footprint fits within the target's
||| available RAM. Returns Ok if it fits, OutOfMemory otherwise.
export
%foreign "C:lustreiser_check_memory_fit, liblustreiser"
prim__checkMemoryFit : Bits64 -> Bits32 -> PrimIO Bits32

||| Safe wrapper for memory fit check
export
checkMemoryFit : Handle -> (availableRAM : Bits32) -> IO (Either Result ())
checkMemoryFit h ram = do
  result <- primIO (prim__checkMemoryFit (handlePtr h) ram)
  pure $ case result of
    0 => Right ()
    3 => Left OutOfMemory
    _ => Left Error

--------------------------------------------------------------------------------
-- String Operations
--------------------------------------------------------------------------------

||| Convert C string to Idris String
export
%foreign "support:idris2_getString, libidris2_support"
prim__getString : Bits64 -> String

||| Free C string allocated by the library
export
%foreign "C:lustreiser_free_string, liblustreiser"
prim__freeString : Bits64 -> PrimIO ()

||| Get a diagnostic string from the library
export
%foreign "C:lustreiser_get_string, liblustreiser"
prim__getResult : Bits64 -> PrimIO Bits64

||| Safe string getter
export
getString : Handle -> IO (Maybe String)
getString h = do
  ptr <- primIO (prim__getResult (handlePtr h))
  if ptr == 0
    then pure Nothing
    else do
      let str = prim__getString ptr
      primIO (prim__freeString ptr)
      pure (Just str)

--------------------------------------------------------------------------------
-- Error Handling
--------------------------------------------------------------------------------

||| Get last error message
export
%foreign "C:lustreiser_last_error, liblustreiser"
prim__lastError : PrimIO Bits64

||| Retrieve last error as string
export
lastError : IO (Maybe String)
lastError = do
  ptr <- primIO prim__lastError
  if ptr == 0
    then pure Nothing
    else pure (Just (prim__getString ptr))

||| Get error description for result code
export
errorDescription : Result -> String
errorDescription Ok = "Success"
errorDescription Error = "Generic error"
errorDescription InvalidParam = "Invalid parameter"
errorDescription OutOfMemory = "Static memory budget exceeded"
errorDescription NullPointer = "Null pointer"
errorDescription DeadlineViolation = "WCET exceeds clock period — synchronous hypothesis violated"
errorDescription ClockError = "Clock calculus inconsistency — stream has ambiguous sampling rate"

--------------------------------------------------------------------------------
-- Version Information
--------------------------------------------------------------------------------

||| Get library version
export
%foreign "C:lustreiser_version, liblustreiser"
prim__version : PrimIO Bits64

||| Get version as string
export
version : IO String
version = do
  ptr <- primIO prim__version
  pure (prim__getString ptr)

||| Get library build info
export
%foreign "C:lustreiser_build_info, liblustreiser"
prim__buildInfo : PrimIO Bits64

||| Get build information
export
buildInfo : IO String
buildInfo = do
  ptr <- primIO prim__buildInfo
  pure (prim__getString ptr)

--------------------------------------------------------------------------------
-- Callback Support
--------------------------------------------------------------------------------

||| Callback function type for node execution monitoring (C ABI).
||| Called after each node step with the node name pointer and WCET used.
public export
Callback : Type
Callback = Bits64 -> Bits32 -> Bits32

||| Register a timing monitor callback.
||| The callback fires after each node step with actual execution time.
export
%foreign "C:lustreiser_register_callback, liblustreiser"
prim__registerCallback : Bits64 -> AnyPtr -> PrimIO Bits32

-- TODO: Implement safe callback registration.
-- The callback must be wrapped via a proper FFI callback mechanism.
-- Do NOT use cast — it is banned per project safety standards.
-- See: https://idris2.readthedocs.io/en/latest/ffi/ffi.html#callbacks

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

||| Check if library is initialised
export
%foreign "C:lustreiser_is_initialized, liblustreiser"
prim__isInitialized : Bits64 -> PrimIO Bits32

||| Check initialisation status
export
isInitialized : Handle -> IO Bool
isInitialized h = do
  result <- primIO (prim__isInitialized (handlePtr h))
  pure (result /= 0)
