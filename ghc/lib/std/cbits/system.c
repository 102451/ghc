/* 
 * (c) The GRASP/AQUA Project, Glasgow University, 1994-1998
 *
 * $Id: system.c,v 1.15 2001/06/29 11:35:14 simonpj Exp $
 *
 * system Runtime Support
 */

/* The itimer stuff in this module is non-posix */
#define NON_POSIX_SOURCE

#include "HsStd.h"

#if defined(mingw32_TARGET_OS)
#include <windows.h>
#endif

HsInt
systemCmd(HsAddr cmd)
{
  /* -------------------- WINDOWS VERSION --------------------- */
#if defined(mingw32_TARGET_OS)
  STARTUPINFO sInfo;
  PROCESS_INFORMATION pInfo;
  DWORD retCode;

  sInfo.cb              = sizeof(STARTUPINFO);
  sInfo.lpReserved      = NULL;
  sInfo.lpReserved2     = NULL;
  sInfo.cbReserved2     = 0;
  sInfo.lpDesktop       = NULL;
  sInfo.lpTitle         = NULL;
  sInfo.dwFlags         = 0;

  if (!CreateProcess(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &sInfo, &pInfo))
    return -1;
  WaitForSingleObject(pInfo.hProcess, INFINITE);
  if (GetExitCodeProcess(pInfo.hProcess, &retCode) == 0) return -1;
  CloseHandle(pInfo.hProcess);
  CloseHandle(pInfo.hThread);
  return retCode;

#else
  /* -------------------- UNIX VERSION --------------------- */
    int pid;
    int wstat;

    switch(pid = fork()) {
    case -1:
	if (errno != EINTR) {
	    return -1;
	}
    case 0:
      {
#ifdef HAVE_SETITIMER
	/* Reset the itimers in the child, so it doesn't get plagued
	 * by SIGVTALRM interrupts.
	 */
	struct timeval tv_null = { 0, 0 };
	struct itimerval itv;
	itv.it_interval = tv_null;
	itv.it_value = tv_null;
	setitimer(ITIMER_REAL, &itv, NULL);
	setitimer(ITIMER_VIRTUAL, &itv, NULL);
	setitimer(ITIMER_PROF, &itv, NULL);
#endif

	/* the child */
	execl("/bin/sh", "sh", "-c", cmd, NULL);
	_exit(127);
      }
    }

    while (waitpid(pid, &wstat, 0) < 0) {
	if (errno != EINTR) {
	    return -1;
	}
    }

    if (WIFEXITED(wstat))
	return WEXITSTATUS(wstat);
    else if (WIFSIGNALED(wstat)) {
	errno = EINTR;
    }
    else {
	/* This should never happen */
    }
    return -1;
#endif
}
