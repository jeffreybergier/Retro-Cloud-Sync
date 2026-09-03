#ifndef RC_ICLOUD_CREDENTIALS_H
#define RC_ICLOUD_CREDENTIALS_H

#include "RCError.h"

#include <stddef.h>

int RCICloudCredentialsSave(const char *username, const void *password,
                            size_t passwordLength,
                            const char *installedDaemonPath, RCError *error);
int RCICloudCredentialsCopyPassword(const char *username, char **password,
                                    size_t *passwordLength, RCError *error);
int RCICloudCredentialsExist(const char *username);
int RCICloudCredentialsRefreshAccess(const char *username,
                                     const char *installedDaemonPath,
                                     RCError *error);
int RCICloudCredentialsRemove(const char *username, RCError *error);
void RCICloudCredentialsClearPassword(char *password, size_t passwordLength);

#endif
