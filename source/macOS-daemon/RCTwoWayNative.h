#ifndef RC_TWO_WAY_NATIVE_H
#define RC_TWO_WAY_NATIVE_H
#import "RCTwoWaySync.h"
#include "RCContactStore.h"
#include "RCCalendarStore.h"
NSDictionary *RCContactNativePaths(NSData *, NSDictionary *, NSString *, RCError *);
NSDictionary *RCContactNativeGraphForPaths(NSData *, NSDictionary *, RCError *);
NSDictionary *RCContactNativeGraphWithPhotoCache(RCContactStore *, NSData *, NSDictionary *, NSString *, NSString *, RCError *);
NSDictionary *RCContactNativeGraph(RCContactStore *, long long, const char *, NSData *, RCError *);
NSDictionary *RCCalendarNativeGraph(RCCalendarStore *, long long, NSString *, NSData *, RCError *);
NSDictionary *RCCalendarProjectVerified(void *, NSDictionary *, NSData *, RCError *);
NSDictionary *RCContactProjectVerified(void *, NSDictionary *, NSData *, RCError *);
int RCExchangeContacts(RCContactStore *, const char *, RCBackendExchange, BOOL, long *, RCError *);
int RCExchangeCalendars(RCCalendarStore *, const char *, RCBackendExchange, BOOL requireCurrentMapping, BOOL, long *, RCError *);
/* Used by the offline mapper tests as well as the production coordinator. */
NSMutableDictionary *RCContactEncodeLocal(void *, NSDictionary *, NSDictionary *, NSString *, RCError *);
NSMutableDictionary *RCCalendarEncodeLocal(void *, NSDictionary *, NSDictionary *, NSString *, RCError *);
#endif
