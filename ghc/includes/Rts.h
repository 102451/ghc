/* -----------------------------------------------------------------------------
 * $Id: Rts.h,v 1.27 2004/09/06 11:10:34 simonmar Exp $
 *
 * (c) The GHC Team, 1998-1999
 *
 * Top-level include file for the RTS itself
 *
 * ---------------------------------------------------------------------------*/

#ifndef RTS_H
#define RTS_H

#ifdef __cplusplus
extern "C" {
#endif

#ifndef IN_STG_CODE
#define IN_STG_CODE 0
#endif
#include "Stg.h"

#include "RtsTypes.h"

#if __GNUC__ >= 3
/* Assume that a flexible array member at the end of a struct
 * can be defined thus: T arr[]; */
#define FLEXIBLE_ARRAY
#else
/* Assume that it must be defined thus: T arr[0]; */
#define FLEXIBLE_ARRAY 0
#endif

#if defined(SMP) || defined(THREADED_RTS)
#define RTS_SUPPORTS_THREADS 1
#endif

/* Fix for mingw stat problem (done here so it's early enough) */
#ifdef mingw32_TARGET_OS
#define __MSVCRT__ 1
#endif

#if defined(__GNUC__)
#define GNU_ATTRIBUTE(at) __attribute__((at))
#else
#define GNU_ATTRIBUTE(at)
#endif

#if __GNUC__ >= 3 
#define GNUC3_ATTRIBUTE(at) __attribute__((at))
#else
#define GNUC3_ATTRIBUTE(at)
#endif

/* 
 * Empty structures isn't supported by all, so to define
 * empty structures, please protect the defn with an
 * #if SUPPORTS_EMPTY_STRUCTS. Similarly for use,
 * employ the macro MAYBE_EMPTY_STRUCT():
 *
 *     MAYBE_EMPTY_STRUCT(structFoo, fieldName);
 */
#if SUPPORTS_EMPTY_STRUCTS
# define MAYBE_EMPTY_STRUCT(a,b) a b;
#else
# define MAYBE_EMPTY_STRUCT(a,b) /* empty */
#endif

/*
 * We often want to know the size of something in units of an
 * StgWord... (rounded up, of course!)
 */
#define sizeofW(t) ((sizeof(t)+sizeof(W_)-1)/sizeof(W_))

/* 
 * It's nice to be able to grep for casts
 */
#define stgCast(ty,e) ((ty)(e))

/* -----------------------------------------------------------------------------
   Assertions and Debuggery
   -------------------------------------------------------------------------- */

#ifndef DEBUG
#define ASSERT(predicate) /* nothing */
#else

void _stgAssert (char *, unsigned int);

#define ASSERT(predicate)			\
	if (predicate)				\
	    /*null*/;				\
	else					\
	    _stgAssert(__FILE__, __LINE__)
#endif /* DEBUG */

/* 
 * Use this on the RHS of macros which expand to nothing
 * to make sure that the macro can be used in a context which
 * demands a non-empty statement.
 */

#define doNothing() do { } while (0)

/* -----------------------------------------------------------------------------
   Include everything STG-ish
   -------------------------------------------------------------------------- */

/* System headers: stdlib.h is eeded so that we can use NULL.  It must
 * come after MachRegs.h, because stdlib.h might define some inline
 * functions which may only be defined after register variables have
 * been declared.
 */
#include <stdlib.h>

/* Global constaints */
#include "Constants.h"

/* Profiling information */
#include "StgProf.h"
#include "StgLdvProf.h"

/* Storage format definitions */
#include "StgFun.h"
#include "Closures.h"
#include "Liveness.h"
#include "ClosureTypes.h"
#include "InfoTables.h"
#include "TSO.h"

/* Info tables, closures & code fragments defined in the RTS */
#include "StgMiscClosures.h"

/* Simulated-parallel information */
#include "GranSim.h"

/* Parallel information */
#include "Parallel.h"

/* STG/Optimised-C related stuff */
#include "SMP.h"
#include "Block.h"

#ifdef SMP
#include <pthread.h>
#endif

/* GNU mp library */
#include "gmp.h"

/* Macros for STG/C code */
#include "ClosureMacros.h"
#include "StgTicky.h"
#include "Stable.h"

/* Runtime-system hooks */
#include "Hooks.h"
#include "RtsMessages.h"

#include "ieee-flpt.h"

#include "Signals.h"

/* Misc stuff without a home */
DLL_IMPORT_RTS extern char **prog_argv;	/* so we can get at these from Haskell */
DLL_IMPORT_RTS extern int    prog_argc;
DLL_IMPORT_RTS extern char  *prog_name;

extern void stackOverflow(void);

extern void      __decodeDouble (MP_INT *man, I_ *_exp, StgDouble dbl);
extern void      __decodeFloat  (MP_INT *man, I_ *_exp, StgFloat flt);

#if defined(WANT_DOTNET_SUPPORT)
#include "DNInvoke.h"
#endif

/* Initialising the whole adjustor thunk machinery. */
extern void initAdjustor(void);

extern void stg_exit(int n) GNU_ATTRIBUTE(__noreturn__);

/* -----------------------------------------------------------------------------
   RTS Exit codes
   -------------------------------------------------------------------------- */

/* 255 is allegedly used by dynamic linkers to report linking failure */
#define EXIT_INTERNAL_ERROR 254
#define EXIT_DEADLOCK       253
#define EXIT_INTERRUPTED    252
#define EXIT_HEAPOVERFLOW   251
#define EXIT_KILLED         250

/* -----------------------------------------------------------------------------
   Miscellaneous garbage
   -------------------------------------------------------------------------- */

/* declarations for runtime flags/values */
#define MAX_RTS_ARGS 32

#ifdef _WIN32
/* On the yucky side..suppress -Wmissing-declarations warnings when
 * including <windows.h>
 */
extern void* GetCurrentFiber ( void );
extern void* GetFiberData ( void );
#endif

/* -----------------------------------------------------------------------------
   Assertions and Debuggery
   -------------------------------------------------------------------------- */

#define IF_RTSFLAGS(c,s)  if (RtsFlags.c) { s; }

/* -----------------------------------------------------------------------------
   Assertions and Debuggery
   -------------------------------------------------------------------------- */

#ifdef DEBUG
#define IF_DEBUG(c,s)  if (RtsFlags.DebugFlags.c) { s; }
#else
#define IF_DEBUG(c,s)  doNothing()
#endif

#ifdef DEBUG
#define DEBUG_ONLY(s) s
#else
#define DEBUG_ONLY(s) doNothing()
#endif

#if defined(GRAN) && defined(DEBUG)
#define IF_GRAN_DEBUG(c,s)  if (RtsFlags.GranFlags.Debug.c) { s; }
#else
#define IF_GRAN_DEBUG(c,s)  doNothing()
#endif

#if defined(PAR) && defined(DEBUG)
#define IF_PAR_DEBUG(c,s)  if (RtsFlags.ParFlags.Debug.c) { s; }
#else
#define IF_PAR_DEBUG(c,s)  doNothing()
#endif

/* -----------------------------------------------------------------------------
   Attributes
   -------------------------------------------------------------------------- */

#ifdef __GNUC__     /* Avoid spurious warnings                             */
#if (__GNUC__ == 2 && __GNUC_MINOR__ >= 7) || __GNUC__ >= 3
#define STG_NORETURN  __attribute__ ((noreturn))
#define STG_UNUSED    __attribute__ ((unused))
#else
#define STG_NORETURN  
#define STG_UNUSED
#endif
#else
#define STG_NORETURN  
#define STG_UNUSED
#endif

#if defined(__GNUC__)
#define SUPPORTS_TYPEOF
#endif

/* -----------------------------------------------------------------------------
   Useful macros and inline functions
   -------------------------------------------------------------------------- */

#if defined(SUPPORTS_TYPEOF)
#define stg_min(a,b) ({typeof(a) _a = (a), _b = (b); _a <= _b ? _a : _b; })
#define stg_max(a,b) ({typeof(a) _a = (a), _b = (b); _a <= _b ? _b : _a; })
#else
#define stg_min(a,b) ((a) <= (b) ? (a) : (b))
#define stg_max(a,b) ((a) <= (b) ? (b) : (a))
#endif

/* -------------------------------------------------------------------------- */

#ifdef __cplusplus
}
#endif

#endif /* RTS_H */
