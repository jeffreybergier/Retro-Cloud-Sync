#ifndef RC_SQLITE_H
#define RC_SQLITE_H
/* Match headers to the library actually linked on each platform. */
#ifdef __APPLE__
#include <AltivecCore/sqlite3.h>
#else
#include <sqlite3.h>
#endif
#endif
