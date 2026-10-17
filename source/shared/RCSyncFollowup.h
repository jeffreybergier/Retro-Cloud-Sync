#ifndef RC_SYNC_FOLLOWUP_H
#define RC_SYNC_FOLLOWUP_H
/* One immediate reconciliation after a batch of verified uploads. Uploads or
   failures during that follow-up cannot start an unbounded polling loop. */
static inline unsigned int RCSyncFollowupDelay(int uploaded, int *followup,
    unsigned int interval)
{
  if(uploaded && !*followup) { *followup=1; return 0; }
  *followup=0;
  return interval;
}
#endif
