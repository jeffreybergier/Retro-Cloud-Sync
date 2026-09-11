#import <Foundation/Foundation.h>
#include "RCWriteJournal.h"
/* One writer: initialize before starting the worker, stop after joining it. */
void RCStatusStart(NSString *configurationPath, NSDictionary *configuration);
void RCStatusPhase(NSString *service, NSString *phase);
void RCStatusFailure(NSString *service, NSString *code);
void RCStatusFinish(NSString *service, RCWriteJournal *journal, BOOL complete);
void RCStatusSchedule(unsigned int interval);
void RCStatusStopping(void);
void RCStatusStop(void);
