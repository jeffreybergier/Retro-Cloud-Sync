#include "RCPhotoCodec.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int Digit(unsigned char c)
{
  if (c>='A' && c<='Z') return c-'A';
  if (c>='a' && c<='z') return c-'a'+26;
  if (c>='0' && c<='9') return c-'0'+52;
  return c=='+' ? 62 : c=='/' ? 63 : -1;
}
unsigned char *RCPhotoDecodeBytes(const char *text, size_t *length)
{
  size_t used=0;
  unsigned char *data;
  const unsigned char *p=(const unsigned char *)text;
  int quartet[4], n=0, finished=0;
  *length=0;
  if (!text || !*text) return NULL;
  /* Decoding cannot exceed the input length, including whitespace. */
  data=malloc(strlen(text));
  if (!data) return NULL;
  for (; *p; p++) {
    int value;
    if (*p==' ' || *p=='\t' || *p=='\r' || *p=='\n') continue;
    if (finished) goto invalid;
    value=*p=='=' ? -2 : Digit(*p);
    if (value==-1) goto invalid;
    quartet[n++]=value;
    if (n==4) {
      int a=quartet[0], b=quartet[1], c=quartet[2], d=quartet[3];
      if (a<0 || b<0 || (c==-2 && (d!=-2 || (b&15))) ||
          (c>=0 && d==-2 && (c&3))) goto invalid;
      data[used++]=(a<<2)|(b>>4);
      if (c>=0) data[used++]=(b<<4)|(c>>2);
      if (d>=0) data[used++]=(c<<6)|d;
      finished=c==-2 || d==-2; n=0;
    }
  }
  if (n || !used) goto invalid;
  *length=used;
  return data;
invalid:
  free(data);
  return NULL;
}
char *RCPhotoEncodeBytes(const unsigned char *bytes, size_t length)
{
  static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t i;
  char *encoded, *out;
  if (!bytes || !length || length>((size_t)-1)/4*3-3) return NULL;
  out=encoded=malloc(((length+2)/3)*4+1);
  if (!out) return NULL;
  for (i=0;i<length;i+=3) {
    unsigned a=bytes[i], b=i+1<length ? bytes[i+1] : 0, c=i+2<length ? bytes[i+2] : 0;
    *out++=alphabet[a>>2]; *out++=alphabet[((a&3)<<4)|(b>>4)];
    *out++=i+1<length ? alphabet[((b&15)<<2)|(c>>6)] : '=';
    *out++=i+2<length ? alphabet[c&63] : '=';
  }
  *out=0;
  return encoded;
}
const char *RCPhotoMediaType(const unsigned char *p, size_t n)
{
  if (!p) return NULL;
  if (n>=3 && p[0]==255 && p[1]==216 && p[2]==255) return "JPEG";
  if (n>=8 && !memcmp(p,"\211PNG\r\n\032\n",8)) return "PNG";
  if (n>=6 && (!memcmp(p,"GIF87a",6) || !memcmp(p,"GIF89a",6))) return "GIF";
  if (n>=4 && (!memcmp(p,"II\052\000",4) || !memcmp(p,"MM\000\052",4))) return "TIFF";
  return NULL;
}
unsigned char *RCPhotoFromVCard(RCVCardDocument *document, size_t *length)
{
  RCVCardProperty *photo=NULL;
  size_t i;
  int binary=0;
  *length=0;
  for (i=0;i<document->propertyCount;i++) if (!strcasecmp(document->properties[i].name,"PHOTO")) {
    if (photo) return NULL;
    photo=&document->properties[i];
  }
  if (!photo) return NULL;
  for (i=0;i<photo->parameterCount;i++) {
    RCVCardParameter *p=&photo->parameters[i];
    if (!strcasecmp(p->name,"ENCODING")) {
      if (strcasecmp(p->value,"b") && strcasecmp(p->value,"BASE64")) return NULL;
      binary=1;
    }
    if (!strcasecmp(p->name,"VALUE") && strcasecmp(p->value,"binary")) return NULL;
  }
  return binary ? RCPhotoDecodeBytes(photo->originalValue,length) : NULL;
}
