/* Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- Copyright (C) 2009 Tobias Markmann
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* pposix.c
* POSIX support functions for Lua
*/

#define MODULE_VERSION "0.3.0"

#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <syslog.h>
#include <pwd.h>

#include <string.h>
#include <errno.h>
#include "lua.h"
#include "lauxlib.h"

/* Daemonization support */

static int lc_daemonize(lua_State *L)
{

	pid_t pid;
	
	if ( getppid() == 1 )
	{
		lua_pushboolean(L, 0);
		lua_pushstring(L, "already-daemonized");
		return 2;
	}
	
	/* Attempt initial fork */
	if((pid = fork()) < 0)
	{
		/* Forking failed */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "fork-failed");
		return 2;
	}
	else if(pid != 0)
	{
		/* We are the parent process */
		lua_pushboolean(L, 1);
		lua_pushnumber(L, pid);
		return 2;
	}
	
	/* and we are the child process */
	if(setsid() == -1)
	{
		/* We failed to become session leader */
		/* (we probably already were) */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "setsid-failed");
		return 2;
	}

	/* Close stdin, stdout, stderr */
	close(0);
	close(1);
	close(2);

	/* Final fork, use it wisely */
	if(fork())
		exit(0);

	/* Show's over, let's continue */
	lua_pushboolean(L, 1);
	lua_pushnil(L);
	return 2;
}

/* Syslog support */

const char * const facility_strings[] = {
					"auth",
					"authpriv",
					"cron",
					"daemon",
					"ftp",
					"kern",
					"local0",
					"local1",
					"local2",
					"local3",
					"local4",
					"local5",
					"local6",
					"local7",
					"lpr",
					"mail",
					"syslog",
					"user",
					"uucp",
					NULL
				};
int facility_constants[] =	{
					LOG_AUTH,
					LOG_AUTHPRIV,
					LOG_CRON,
					LOG_DAEMON,
					LOG_FTP,
					LOG_KERN,
					LOG_LOCAL0,
					LOG_LOCAL1,
					LOG_LOCAL2,
					LOG_LOCAL3,
					LOG_LOCAL4,
					LOG_LOCAL5,
					LOG_LOCAL6,
					LOG_LOCAL7,
					LOG_LPR,
					LOG_MAIL,
					LOG_NEWS,
					LOG_SYSLOG,
					LOG_USER,
					LOG_UUCP,
					-1
				};

/* "
       The parameter ident in the call of openlog() is probably stored  as-is.
       Thus,  if  the  string  it  points  to  is  changed, syslog() may start
       prepending the changed string, and if the string it points to ceases to
       exist,  the  results  are  undefined.  Most portable is to use a string
       constant.
   " -- syslog manpage
*/ 
char* syslog_ident = NULL;

int lc_syslog_open(lua_State* L)
{
	int facility = luaL_checkoption(L, 2, "daemon", facility_strings);
	facility = facility_constants[facility];

	luaL_checkstring(L, 1);
	
	if(syslog_ident)
		free(syslog_ident);
	
	syslog_ident = strdup(lua_tostring(L, 1));
	
	openlog(syslog_ident, LOG_PID, facility);
	return 0;
}

const char * const level_strings[] = {
				"debug",
				"info",
				"notice",
				"warn",
				"error",
				NULL
			};
int level_constants[] = 	{
				LOG_DEBUG,
				LOG_INFO,
				LOG_NOTICE,
				LOG_WARNING,
				LOG_CRIT,
				-1
			};
int lc_syslog_log(lua_State* L)
{
	int level = luaL_checkoption(L, 1, "notice", level_strings);
	level = level_constants[level];

	luaL_checkstring(L, 2);

	syslog(level, "%s", lua_tostring(L, 2));
	return 0;
}

int lc_syslog_close(lua_State* L)
{
	closelog();
	if(syslog_ident)
	{
		free(syslog_ident);
		syslog_ident = NULL;
	}
	return 0;
}

int lc_syslog_setmask(lua_State* L)
{
	int level_idx = luaL_checkoption(L, 1, "notice", level_strings);
	int mask = 0;
	do
	{
		mask |= LOG_MASK(level_constants[level_idx]);
	} while (++level_idx<=4);

	setlogmask(mask);
	return 0;
}

/* getpid */

int lc_getpid(lua_State* L)
{
	lua_pushinteger(L, getpid());
	return 1;
}

/* UID/GID functions */

int lc_getuid(lua_State* L)
{
	lua_pushinteger(L, getuid());
	return 1;
}

int lc_getgid(lua_State* L)
{
	lua_pushinteger(L, getgid());
	return 1;
}

int lc_setuid(lua_State* L)
{
	int uid = -1;
	if(lua_gettop(L) < 1)
		return 0;
	if(!lua_isnumber(L, 1) && lua_tostring(L, 1))
	{
		/* Passed UID is actually a string, so look up the UID */
		struct passwd *p;
		p = getpwnam(lua_tostring(L, 1));
		if(!p)
		{
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no-such-user");
			return 2;
		}
		uid = p->pw_uid;
	}
	else
	{
		uid = lua_tonumber(L, 1);
	}
	
	if(uid>-1)
	{
		/* Ok, attempt setuid */
		errno = 0;
		if(setuid(uid))
		{
			/* Fail */
			lua_pushboolean(L, 0);
			switch(errno)
			{
			case EINVAL:
				lua_pushstring(L, "invalid-uid");
				break;
			case EPERM:
				lua_pushstring(L, "permission-denied");
				break;
			default:
				lua_pushstring(L, "unknown-error");
			}
			return 2;
		}
		else
		{
			/* Success! */
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	
	/* Seems we couldn't find a valid UID to switch to */
	lua_pushboolean(L, 0);
	lua_pushstring(L, "invalid-uid");
	return 2;
}

/*	Like POSIX's setrlimit()/getrlimit() API functions.
 *	
 *	Syntax:
 *	pposix.setrlimit( resource, soft limit, hard limit)
 *	
 *	Any negative limit will be replace with the current limit by an additional call of getrlimit().
 *	
 *	Example usage:
 *	pposix.setrlimit("NOFILE", 1000, 2000)
 */
int string2resource(const char *s) {
	if (!strcmp(s, "CORE")) return RLIMIT_CORE;
	if (!strcmp(s, "CPU")) return RLIMIT_CPU;
	if (!strcmp(s, "DATA")) return RLIMIT_DATA;
	if (!strcmp(s, "FSIZE")) return RLIMIT_FSIZE;
	if (!strcmp(s, "MEMLOCK")) return RLIMIT_MEMLOCK;
	if (!strcmp(s, "NOFILE")) return RLIMIT_NOFILE;
	if (!strcmp(s, "NPROC")) return RLIMIT_NPROC;
	if (!strcmp(s, "RSS")) return RLIMIT_RSS;
	if (!strcmp(s, "STACK")) return RLIMIT_STACK;
	return -1;
}

int lc_setrlimit(lua_State *L) {
	int arguments = lua_gettop(L);
	int softlimit = -1;
	int hardlimit = -1;
	const char *resource = NULL;
	int rid = -1;
	if(arguments < 1 || arguments > 3) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "incorrect-arguments");
	}
	
	resource = luaL_checkstring(L, 1);
	softlimit = luaL_checkinteger(L, 2);
	hardlimit = luaL_checkinteger(L, 3);
	
	rid = string2resource(resource);
	if (rid != -1) {
		struct rlimit lim;
		struct rlimit lim_current;
		
		if (softlimit < 0 || hardlimit < 0) {
			if (getrlimit(rid, &lim_current)) {
				lua_pushboolean(L, 0);
				lua_pushstring(L, "getrlimit-failed");
				return 2;
			}
		}
		
		if (softlimit < 0) lim.rlim_cur = lim_current.rlim_cur;
			else lim.rlim_cur = softlimit;
		if (hardlimit < 0) lim.rlim_max = lim_current.rlim_max;
			else lim.rlim_max = hardlimit;
		
		if (setrlimit(rid, &lim)) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "setrlimit-failed");
			return 2;
		}
	} else {
		/* Unsupported resoucrce. Sorry I'm pretty limited by POSIX standard. */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

int lc_getrlimit(lua_State *L) {
	int arguments = lua_gettop(L);
	const char *resource = NULL;
	int rid = -1;
	struct rlimit lim;
	
	if (arguments != 1) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-arguments");
		return 2;
	}
	
	resource = luaL_checkstring(L, 1);
	rid = string2resource(resource);
	if (rid != -1) {
		if (getrlimit(rid, &lim)) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "getrlimit-failed.");
			return 2;
		}
	} else {
		/* Unsupported resoucrce. Sorry I'm pretty limited by POSIX standard. */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}
	lua_pushboolean(L, 1);
	lua_pushnumber(L, lim.rlim_cur);
	lua_pushnumber(L, lim.rlim_max);
	return 3;
}

/* Register functions */

int luaopen_util_pposix(lua_State *L)
{
	lua_newtable(L);

	lua_pushcfunction(L, lc_daemonize);
	lua_setfield(L, -2, "daemonize");

	lua_pushcfunction(L, lc_syslog_open);
	lua_setfield(L, -2, "syslog_open");

	lua_pushcfunction(L, lc_syslog_close);
	lua_setfield(L, -2, "syslog_close");

	lua_pushcfunction(L, lc_syslog_log);
	lua_setfield(L, -2, "syslog_log");

	lua_pushcfunction(L, lc_syslog_setmask);
	lua_setfield(L, -2, "syslog_setminlevel");

	lua_pushcfunction(L, lc_getpid);
	lua_setfield(L, -2, "getpid");

	lua_pushcfunction(L, lc_getuid);
	lua_setfield(L, -2, "getuid");

	lua_pushcfunction(L, lc_setuid);
	lua_setfield(L, -2, "setuid");
	
	lua_pushcfunction(L, lc_setrlimit);
	lua_setfield(L, -2, "setrlimit");
	
	lua_pushcfunction(L, lc_getrlimit);
	lua_setfield(L, -2, "getrlimit");

	lua_pushliteral(L, "pposix");
	lua_setfield(L, -2, "_NAME");

	lua_pushliteral(L, MODULE_VERSION);
	lua_setfield(L, -2, "_VERSION");
	
	return 1;
};
