/* -----------------------------------------------------------------------------
 * $Id: Proftimer.c,v 1.10 2002/07/18 09:12:34 simonmar Exp $
 *
 * (c) The GHC Team, 1998-1999
 *
 * Profiling interval timer
 *
 * ---------------------------------------------------------------------------*/

#if defined (PROFILING)

#include "PosixSource.h"

#include <stdio.h>

#include "Rts.h"
#include "Profiling.h"
#include "Itimer.h"
#include "Proftimer.h"
#include "RtsFlags.h"

static rtsBool do_prof_ticks = rtsFalse;       // enable profiling ticks
static rtsBool do_heap_prof_ticks = rtsFalse;  // enable heap profiling ticks

// Number of ticks until next heap census
static int ticks_to_heap_profile;

// Time for a heap profile on the next context switch
rtsBool performHeapProfile;

void
stopProfTimer( void )
{
    do_prof_ticks = rtsFalse;
}

void
startProfTimer( void )
{
    do_prof_ticks = rtsTrue;
}

void
stopHeapProfTimer( void )
{
    do_heap_prof_ticks = rtsFalse;
}

void
startHeapProfTimer( void )
{
    if (RtsFlags.ProfFlags.doHeapProfile) {
	do_heap_prof_ticks = rtsTrue;
    }
}

void
initProfTimer( void )
{
    performHeapProfile = rtsFalse;

    RtsFlags.ProfFlags.profileIntervalTicks = 
	RtsFlags.ProfFlags.profileInterval / TICK_MILLISECS;

    ticks_to_heap_profile = RtsFlags.ProfFlags.profileIntervalTicks;

    startHeapProfTimer();
}


void
handleProfTick(void)
{
    if (do_prof_ticks) {
	CCCS->time_ticks++;
    }

    if (do_heap_prof_ticks) {
	ticks_to_heap_profile--;
	if (ticks_to_heap_profile <= 0) {
	    ticks_to_heap_profile = RtsFlags.ProfFlags.profileIntervalTicks;
	    performHeapProfile = rtsTrue;
	}
    }
}

#endif /* PROFILING */
