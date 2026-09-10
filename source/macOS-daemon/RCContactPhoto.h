#ifndef RC_CONTACT_PHOTO_H
#define RC_CONTACT_PHOTO_H
#import <Foundation/Foundation.h>
#include "RCVCard.h"
#include <string.h>
#include <strings.h>

/* NSData's base64 APIs postdate Tiger. Keep binary bytes out of NSString and
   the text vCard decoder; only the ASCII transfer representation is text. */
static inline int RCPhotoDigit(unsigned char c)
{
  if (c>='A' && c<='Z') return c-'A';
  if (c>='a' && c<='z') return c-'a'+26;
  if (c>='0' && c<='9') return c-'0'+52;
  return c=='+' ? 62 : c=='/' ? 63 : -1;
}
static inline NSData *RCPhotoDecode(const char *text)
{
  if (!text) return nil;
  NSMutableData *data=[NSMutableData data];
  int quartet[4], n=0; BOOL finished=NO;
  const unsigned char *p=(const unsigned char *)text;
  for (; *p; p++) {
    if (*p==' ' || *p=='\t' || *p=='\r' || *p=='\n') continue;
    if (finished) return nil;
    int value=*p=='=' ? -2 : RCPhotoDigit(*p);
    if (value==-1) return nil;
    quartet[n++]=value;
    if (n==4) {
      int a=quartet[0], b=quartet[1], c=quartet[2], d=quartet[3];
      if (a<0 || b<0 || (c==-2 && (d!=-2 || (b&15))) ||
          (c>=0 && d==-2 && (c&3))) return nil;
      unsigned char bytes[3];
      bytes[0]=(a<<2)|(b>>4);
      bytes[1]=(b<<4)|(c<0 ? 0 : c>>2);
      bytes[2]=((c<0 ? 0 : c)<<6)|(d<0 ? 0 : d);
      [data appendBytes:bytes length:c==-2 ? 1 : d==-2 ? 2 : 3];
      finished=c==-2 || d==-2; n=0;
    }
  }
  return n==0 && [data length] ? data : nil;
}
static inline NSString *RCPhotoEncode(id image)
{
  if (![image isKindOfClass:[NSData class]] || ![image length]) return nil;
  static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const unsigned char *bytes=[image bytes]; NSUInteger length=[image length], i;
  if (length>NSUIntegerMax/4*3-3) return nil;
  NSMutableData *encoded=[NSMutableData dataWithLength:((length+2)/3)*4];
  char *out=[encoded mutableBytes];
  for(i=0;i<length;i+=3) {
    unsigned a=bytes[i], b=i+1<length ? bytes[i+1] : 0, c=i+2<length ? bytes[i+2] : 0;
    *out++=alphabet[a>>2]; *out++=alphabet[((a&3)<<4)|(b>>4)];
    *out++=i+1<length ? alphabet[((b&15)<<2)|(c>>6)] : '=';
    *out++=i+2<length ? alphabet[c&63] : '=';
  }
  return [[[NSString alloc] initWithData:encoded encoding:NSASCIIStringEncoding] autorelease];
}
static inline NSString *RCPhotoType(NSData *image)
{
  const unsigned char *p=[image bytes]; NSUInteger n=[image length];
  if (n>=3 && p[0]==255 && p[1]==216 && p[2]==255) return @"JPEG";
  if (n>=8 && !memcmp(p,"\211PNG\r\n\032\n",8)) return @"PNG";
  if (n>=6 && (!memcmp(p,"GIF87a",6) || !memcmp(p,"GIF89a",6))) return @"GIF";
  if (n>=4 && (!memcmp(p,"II\052\000",4) || !memcmp(p,"MM\000\052",4))) return @"TIFF";
  return nil; /* TYPE is optional; never guess or transcode the payload. */
}
static inline NSData *RCContactPhoto(RCVCardDocument *document)
{
  RCVCardProperty *photo=NULL; size_t i;
  for(i=0;i<document->propertyCount;i++) if (!strcasecmp(document->properties[i].name,"PHOTO")) {
    if (photo) return nil; /* A single native image cannot represent multiple photos. */
    photo=&document->properties[i];
  }
  if (!photo) return nil;
  BOOL binary=NO;
  for(i=0;i<photo->parameterCount;i++) {
    RCVCardParameter *p=&photo->parameters[i];
    if (!strcasecmp(p->name,"ENCODING")) {
      if (strcasecmp(p->value,"b") && strcasecmp(p->value,"BASE64")) return nil;
      binary=YES;
    }
    if (!strcasecmp(p->name,"VALUE") && strcasecmp(p->value,"binary")) return nil;
  }
  /* Embedded decoding is pure; URI photos are resolved from a versioned cache. */
  return binary ? RCPhotoDecode(photo->originalValue) : nil;
}
/* Network work is separate from mapping and native sync sessions. */
#include "RCContactStore.h"
#include "RCHTTPClient.h"
NSString *RCContactPhotoURI(RCVCardDocument *);
BOOL RCContactPhotoRead(RCContactStore *, RCVCardDocument *, NSString *, NSString *, NSData **, RCError *);
BOOL RCContactPhotoFetch(RCContactStore *, RCHTTPClient *, NSString *, NSString *, NSData *, RCError *);
BOOL RCContactPhotoRefresh(RCContactStore *, RCHTTPClient *, RCError *);
BOOL RCContactPhotoRefreshWrites(RCContactStore *, RCHTTPClient *, RCError *);
#endif
