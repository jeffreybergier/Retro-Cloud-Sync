#ifndef RC_CONTACT_PHOTO_H
#define RC_CONTACT_PHOTO_H
#import <Foundation/Foundation.h>
#include "RCVCard.h"
#include <string.h>
#include <strings.h>

/* Foundation owns only the adapter objects; wire decisions live in C. */
#include "RCPhotoCodec.h"
#include <stdlib.h>
static inline NSData *RCPhotoDecode(const char *text)
{
  size_t length=0; unsigned char *bytes=RCPhotoDecodeBytes(text,&length);
  if (!bytes) return nil;
  NSData *data=[NSData dataWithBytes:bytes length:length]; free(bytes); return data;
}
static inline NSString *RCPhotoEncode(id image)
{
  if (![image isKindOfClass:[NSData class]]) return nil;
  char *text=RCPhotoEncodeBytes([image bytes],[image length]);
  if (!text) return nil;
  NSString *result=[NSString stringWithUTF8String:text]; free(text); return result;
}
static inline NSString *RCPhotoType(NSData *image)
{
  const char *type=RCPhotoMediaType([image bytes],[image length]);
  return type ? [NSString stringWithUTF8String:type] : nil;
}
static inline NSData *RCContactPhoto(RCVCardDocument *document)
{
  size_t length=0; unsigned char *bytes=RCPhotoFromVCard(document,&length);
  if (!bytes) return nil;
  NSData *data=[NSData dataWithBytes:bytes length:length]; free(bytes); return data;
}
/* Network work is separate from mapping and native sync sessions. */
#include "RCContactStore.h"
#include "RCHTTPClient.h"
NSString *RCContactPhotoURI(RCVCardDocument *);
BOOL RCContactPhotoRead(RCContactStore *, RCVCardDocument *, NSString *, NSString *, NSData **, RCError *);
BOOL RCContactPhotoFetch(RCContactStore *, RCHTTPClient *, NSString *, NSString *, NSData *, RCError *);
typedef void (*RCContactPhotoProgress)(NSUInteger completed, NSUInteger total, void *context);
BOOL RCContactPhotoRefresh(RCContactStore *, RCHTTPClient *, RCContactPhotoProgress, void *, RCError *);
BOOL RCContactPhotoRefreshWrites(RCContactStore *, RCHTTPClient *, RCError *);
#endif
