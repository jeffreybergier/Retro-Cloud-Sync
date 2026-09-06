#include "CalendarFixtures.h"
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
  RCCalendarStore *store;
  RCError error;
  int ok;
  if (argc != 3 || (strcmp(argv[1], "initial") && strcmp(argv[1], "updated") &&
      strcmp(argv[1], "empty") && strcmp(argv[1], "malformed") &&
      strcmp(argv[1], "missing-uid") && strcmp(argv[1], "unsupported"))) {
    fprintf(stderr, "usage: %s initial|updated|empty|malformed|missing-uid|unsupported DATABASE\n", argv[0]);
    return 2;
  }
  RCErrorClear(&error);
  store = RCCalendarStoreOpen(argv[2], "calendar-test", &error);
  ok = store && RCCalendarFixturePopulate(store, argv[1], &error);
  if (!ok) fprintf(stderr, "Calendar fixture: %s\n", error.message);
  RCCalendarStoreClose(store);
  return ok ? 0 : 1;
}
