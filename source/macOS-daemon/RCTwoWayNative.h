#ifndef RC_TWO_WAY_NATIVE_H
#define RC_TWO_WAY_NATIVE_H
#import "RCTwoWaySync.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
NSDictionary *RCContactNativePaths(NSData *, NSDictionary *, NSString *, RCError *);
NSDictionary *RCContactNativeGraphForPaths(NSData *, NSDictionary *, RCError *);
NSDictionary *RCContactNativeGraph(RCContactStore *, long long, const char *, NSData *, RCError *);
NSDictionary *RCCalendarNativeGraph(RCCalendarStore *, long long, NSString *, NSData *, RCError *);
NSDictionary *RCCalendarProjectVerified(void *, NSDictionary *, NSData *, RCError *);
NSDictionary *RCContactProjectVerified(void *, NSDictionary *, NSData *, RCError *);
/* A successful partial exchange reports -1; its full mirror is not checkpointed. */
int RCSyncServicesTwoWayContacts(RCContactStore *, const char *, long *, RCError *);
int RCSyncServicesTwoWayCalendars(RCCalendarStore *, const char *, long *, RCError *);
/* Used by the offline mapper tests as well as the production coordinator. */
NSMutableDictionary *RCContactEncodeLocal(void *, NSDictionary *, NSDictionary *, NSString *, RCError *);
NSMutableDictionary *RCCalendarEncodeLocal(void *, NSDictionary *, NSDictionary *, NSString *, RCError *);
#endif
