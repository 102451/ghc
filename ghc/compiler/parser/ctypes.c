/*-----------------------------------------------------------------------------
  ctype.c for Haskell

  (c) Simon Marlow 1993
-----------------------------------------------------------------------------*/

#include "ctypes.h"

const unsigned char char_types[] = 
  {
    0,				/* \000 */
    0,				/* \001 */
    0,				/* \002 */
    0,				/* \003 */
    0,				/* \004 */
    0,				/* \005 */
    0,				/* \006 */
    0,				/* \007 */
    0,				/* \010 */
    C_Any | C_Space,   	  	/* \t */
    C_Any | C_Space,		/* \n */
    C_Any | C_Space,		/* \v */
    C_Any | C_Space,		/* \f */
    0,				/* \015 */
    0,				/* \016 */
    0,				/* \017 */
    0,				/* \020 */
    0,				/* \021 */
    0,				/* \022 */
    0,				/* \023 */
    0,				/* \024 */
    0,				/* \025 */
    0,				/* \026 */
    0,				/* \027 */
    0,				/* \030 */
    0,				/* \031 */
    0,				/* \032 */
    0,				/* \033 */
    0,				/* \034 */
    0,				/* \035 */
    0,				/* \036 */
    0,				/* \037 */
    C_Any | C_Space,		/*   */
    C_Any | C_Symbol,		/* ! */
    C_Any,			/* " */
    C_Any | C_Symbol,		/* # */
    C_Any | C_Symbol,		/* $ */
    C_Any | C_Symbol,		/* % */
    C_Any | C_Symbol,		/* & */
    C_Any | C_Ident,		/* ' */
    C_Any,			/* ( */
    C_Any,			/* ) */
    C_Any | C_Symbol,		/* * */
    C_Any | C_Symbol,		/* + */
    C_Any,			/* , */
    C_Any | C_Symbol,           /* - */
    C_Any | C_Symbol,		/* . */
    C_Any | C_Symbol,		/* / */
    C_Any | C_Ident | C_Digit,	/* 0 */
    C_Any | C_Ident | C_Digit,	/* 1 */
    C_Any | C_Ident | C_Digit,	/* 2 */
    C_Any | C_Ident | C_Digit,	/* 3 */
    C_Any | C_Ident | C_Digit,	/* 4 */
    C_Any | C_Ident | C_Digit,	/* 5 */
    C_Any | C_Ident | C_Digit,	/* 6 */
    C_Any | C_Ident | C_Digit,	/* 7 */
    C_Any | C_Ident | C_Digit,	/* 8 */
    C_Any | C_Ident | C_Digit,	/* 9 */
    C_Any | C_Symbol,		/* : */
    C_Any,			/* ; */
    C_Any | C_Symbol,		/* < */
    C_Any | C_Symbol,		/* = */
    C_Any | C_Symbol,		/* > */
    C_Any | C_Symbol,		/* ? */
    C_Any | C_Symbol,		/* @ */
    C_Any | C_Ident | C_Upper,	/* A */
    C_Any | C_Ident | C_Upper,	/* B */
    C_Any | C_Ident | C_Upper,	/* C */
    C_Any | C_Ident | C_Upper,	/* D */
    C_Any | C_Ident | C_Upper,	/* E */
    C_Any | C_Ident | C_Upper,	/* F */
    C_Any | C_Ident | C_Upper,	/* G */
    C_Any | C_Ident | C_Upper,	/* H */
    C_Any | C_Ident | C_Upper,	/* I */
    C_Any | C_Ident | C_Upper,	/* J */
    C_Any | C_Ident | C_Upper,	/* K */
    C_Any | C_Ident | C_Upper,	/* L */
    C_Any | C_Ident | C_Upper,	/* M */
    C_Any | C_Ident | C_Upper,	/* N */
    C_Any | C_Ident | C_Upper,	/* O */
    C_Any | C_Ident | C_Upper,	/* P */
    C_Any | C_Ident | C_Upper,	/* Q */
    C_Any | C_Ident | C_Upper,	/* R */
    C_Any | C_Ident | C_Upper,	/* S */
    C_Any | C_Ident | C_Upper,	/* T */
    C_Any | C_Ident | C_Upper,	/* U */
    C_Any | C_Ident | C_Upper,	/* V */
    C_Any | C_Ident | C_Upper,	/* W */
    C_Any | C_Ident | C_Upper,	/* X */
    C_Any | C_Ident | C_Upper,	/* Y */
    C_Any | C_Ident | C_Upper,	/* Z */
    C_Any,			/* [ */
    C_Any | C_Symbol,		/* \ */
    C_Any,			/* ] */
    C_Any | C_Symbol,		/* ^ */
    C_Any | C_Ident,		/* _ */
    C_Any,			/* ` */
    C_Any | C_Ident,		/* a */
    C_Any | C_Ident,		/* b */
    C_Any | C_Ident,		/* c */
    C_Any | C_Ident,		/* d */
    C_Any | C_Ident,		/* e */
    C_Any | C_Ident,		/* f */
    C_Any | C_Ident,		/* g */
    C_Any | C_Ident,		/* h */
    C_Any | C_Ident,		/* i */
    C_Any | C_Ident,		/* j */
    C_Any | C_Ident,		/* k */
    C_Any | C_Ident,		/* l */
    C_Any | C_Ident,		/* m */
    C_Any | C_Ident,		/* n */
    C_Any | C_Ident,		/* o */
    C_Any | C_Ident,		/* p */
    C_Any | C_Ident,		/* q */
    C_Any | C_Ident,		/* r */
    C_Any | C_Ident,		/* s */
    C_Any | C_Ident,		/* t */
    C_Any | C_Ident,		/* u */
    C_Any | C_Ident,		/* v */
    C_Any | C_Ident,		/* w */
    C_Any | C_Ident,		/* x */
    C_Any | C_Ident,		/* y */
    C_Any | C_Ident,		/* z */
    C_Any,			/* { */
    C_Any | C_Symbol,		/* | */
    C_Any,			/* } */
    C_Any | C_Symbol,		/* ~ */
    0,				/* \177 */
    0,				/* \200 */
    0,				/* \201 */
    0,				/* \202 */
    0,				/* \203 */
    0,				/* \204 */
    0,				/* \205 */
    0,				/* \206 */
    0,				/* \207 */
    0,				/* \210 */
    0,				/* \211 */
    0,				/* \212 */
    0,				/* \213 */
    0,				/* \214 */
    0,				/* \215 */
    0,				/* \216 */
    0,				/* \217 */
    0,				/* \220 */
    0,				/* \221 */
    0,				/* \222 */
    0,				/* \223 */
    0,				/* \224 */
    0,				/* \225 */
    0,				/* \226 */
    0,				/* \227 */
    0,				/* \230 */
    0,				/* \231 */
    0,				/* \232 */
    0,				/* \233 */
    0,				/* \234 */
    0,				/* \235 */
    0,				/* \236 */
    0,				/* \237 */
    C_Space,			/*   */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident | C_Upper,	/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Symbol,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
    C_Any | C_Ident,		/* � */
  };
