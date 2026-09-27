#ifndef RC_PHOTO_CODEC_H
#define RC_PHOTO_CODEC_H
#include <stddef.h>
#include "RCVCard.h"
/* Returned buffers belong to the caller. Invalid/empty input returns NULL. */
unsigned char *RCPhotoDecodeBytes(const char *text, size_t *length);
char *RCPhotoEncodeBytes(const unsigned char *bytes, size_t length);
const char *RCPhotoMediaType(const unsigned char *bytes, size_t length);
unsigned char *RCPhotoFromVCard(RCVCardDocument *document, size_t *length);
#endif
