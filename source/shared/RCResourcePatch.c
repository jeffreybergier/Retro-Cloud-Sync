#include "RCResourcePatch.h"
#include "RCVCard.h"
#include "RCICalendar.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <limits.h>

typedef struct { unsigned char *data; size_t length; } Buffer;
typedef struct { size_t start, end; Buffer replacement; int found, seen; } Patch;
static int add(Buffer *b, const void *p, size_t n)
{
  unsigned char *next;
  if (n > (size_t)INT_MAX || b->length > (size_t)INT_MAX - n) return 0;
  next = realloc(b->data,b->length+n+1);
  if (!next) return 0;
  b->data=next;
  if (n) memcpy(next+b->length,p,n);
  b->length+=n; next[b->length]=0; return 1;
}
static int valid(RCResourceFormat format, const unsigned char *b, size_t n, RCError *e)
{
  if (format == RCResourceVCard) {
    RCVCardDocument d;
    int ok = RCVCardParse(b,n,&d,e);
    RCVCardDocumentClear(&d); return ok;
  } else {
    icalcomponent *c = RCICalendarParse(b,n,e);
    if (!c) return 0;
    icalcomponent_free(c); return 1;
  }
}
static int token(const char *s)
{
  if (!s || !*s) return 0;
  for (; *s; s++)
    if (!((*s>='A' && *s<='Z') || (*s>='a' && *s<='z') ||
          (*s>='0' && *s<='9') || *s=='-')) return 0;
  return 1;
}
static int allowed(const char *component, const char *name)
{
  const char *fields;
  char wanted[80];
  size_t i;
  if (!strcmp(component,"VCARD")) fields = "|N|FN|NICKNAME|ORG|TITLE|BDAY|NOTE|TEL|EMAIL|ADR|URL|X-ABLABEL|X-ABADR|X-ABSHOWAS|";
  else if (!strcmp(component,"VEVENT")) fields = "|SUMMARY|DESCRIPTION|LOCATION|URL|DTSTART|DTEND|DURATION|STATUS|CLASS|PRIORITY|RRULE|EXDATE|ORGANIZER|ATTENDEE|";
  else if (!strcmp(component,"VALARM")) fields = "|DESCRIPTION|SUMMARY|TRIGGER|REPEAT|DURATION|ACTION|";
  else return 0;
  if (strlen(name)>sizeof(wanted)-3) return 0;
  wanted[0]='|';
  for(i=0; name[i]; i++) wanted[i+1]=(name[i]>='a' && name[i]<='z') ? name[i]-'a'+'A' : name[i];
  wanted[i+1]='|'; wanted[i+2]=0;
  return strstr(fields,wanted)!=NULL;
}
/* Find the value separator outside quoted parameters. */
static char *colon(char *line)
{
  int quoted=0;
  for (; *line; line++) {
    if (*line=='"') quoted=!quoted;
    if (*line==':' && !quoted) return line;
  }
  return NULL;
}
static int folded(Buffer *out, const char *prefix, size_t plen, const char *value)
{
  Buffer line={NULL,0};
  size_t pos=0;
  int ok=0;
  if (!add(&line,prefix,plen) || !add(&line,value,strlen(value))) goto done;
  while (pos<line.length) {
    size_t n=line.length-pos, limit=pos ? 74 : 75;
    if (n>limit) {
      n=limit;
      while (n && (line.data[pos+n]&0xc0)==0x80) n--;
      if (!n) goto done;
    }
    if ((pos && !add(out," ",1)) || !add(out,line.data+pos,n) || !add(out,"\r\n",2)) goto done;
    pos+=n;
  }
  ok=1;
done:
  free(line.data); return ok;
}
int RCResourcePatch(RCResourceFormat format, const unsigned char *base, size_t length,
    const RCResourceEdit *edits, size_t count, unsigned char **output,
    size_t *outputLength, RCError *e)
{
  Patch *patches=NULL;
  Buffer result={NULL,0}, line={NULL,0};
  size_t stack[64], depth=0, components=0, pos=0, i, cursor=0;
  char kinds[64][32];
  int ok=0, closed=0;
  const char *reason;
  size_t editIndex=(size_t)-1;
  *output=NULL; *outputLength=0;
  if ((format!=RCResourceVCard && format!=RCResourceCalendar) || !base || !length ||
      length>INT_MAX || memchr(base,0,length) || (count && !edits) || count>10000) {
    RCErrorSet(e,1,"Invalid resource patch input"); return 0;
  }
  if (!valid(format,base,length,e)) return 0;
  patches=calloc(count ? count : 1,sizeof(*patches));
  if (!patches) goto memory;
  for (i=0;i<count;i++) {
    editIndex=i; reason="invalid property, occurrence, or unescaped newline";
    if (!token(edits[i].property) || (edits[i].group && !token(edits[i].group)) ||
        edits[i].occurrence < -1 || (edits[i].occurrence == -1 && !edits[i].value) ||
        (edits[i].value && (strchr(edits[i].value,'\r') || strchr(edits[i].value,'\n')))) goto invalid;
    if (edits[i].parameters) {
      reason="invalid insertion parameters";
      const char *p=edits[i].parameters;
      if (edits[i].occurrence!=-1 || !*p || !strchr(p,'=')) goto invalid;
      for (;*p;p++) if (!((*p>='a' && *p<='z') || (*p>='A' && *p<='Z') ||
          (*p>='0' && *p<='9') || strchr("=,;-_./",*p))) goto invalid;
    }
  }
  while (pos<length) {
    size_t start=pos, n;
    editIndex=(size_t)-1; reason="invalid component structure";
    char *sep, *nameEnd, *dot, *name;
    free(line.data); memset(&line,0,sizeof(line));
    do {
      size_t begin=pos;
      while (pos<length && base[pos]!='\r' && base[pos]!='\n') pos++;
      if (!add(&line,base+begin,pos-begin)) goto memory;
      if (pos<length && base[pos]=='\r') pos++;
      if (pos<length && base[pos]=='\n') pos++;
      if (pos>=length || (base[pos]!=' ' && base[pos]!='\t')) break;
      pos++;
    } while (pos<length);
    if (!line.length) continue;
    sep=colon((char *)line.data);
    if (!sep) goto invalid;
    if (!strncasecmp((char *)line.data,"BEGIN:",6)) {
      if (closed || depth==64 || strlen(sep+1)>=sizeof(kinds[0])) goto invalid;
      if (!depth && strcasecmp(sep+1,format==RCResourceVCard ? "VCARD" : "VCALENDAR")) goto invalid;
      if (format==RCResourceVCard && depth) goto invalid;
      stack[depth]=components++;
      for(n=0;sep[1+n];n++) kinds[depth][n]=(sep[1+n]>='a' && sep[1+n]<='z') ? sep[1+n]-'a'+'A' : sep[1+n];
      kinds[depth][n]=0; depth++; continue;
    }
    if (!depth) goto invalid;
    if (!strncasecmp((char *)line.data,"END:",4)) {
      if (strcasecmp(sep+1,kinds[depth-1])) goto invalid;
      for (i=0;i<count;i++) if (edits[i].component==stack[depth-1] && edits[i].occurrence==-1) {
        Buffer prefix={NULL,0};
        editIndex=i; reason="property is not writable in this component";
        if (!allowed(kinds[depth-1],edits[i].property)) goto invalid;
        if ((edits[i].group && (!add(&prefix,edits[i].group,strlen(edits[i].group)) || !add(&prefix,".",1))) ||
            !add(&prefix,edits[i].property,strlen(edits[i].property)) ||
            (edits[i].parameters && (!add(&prefix,";",1) ||
              !add(&prefix,edits[i].parameters,strlen(edits[i].parameters)))) || !add(&prefix,":",1) ||
            !folded(&patches[i].replacement,(char *)prefix.data,prefix.length,edits[i].value)) {
          free(prefix.data); goto memory;
        }
        free(prefix.data); patches[i].start=start; patches[i].end=start; patches[i].found=1;
      }
      depth--; if (!depth) closed=1;
      continue;
    }
    nameEnd=(char *)line.data;
    while (nameEnd<sep && *nameEnd!=';') nameEnd++;
    dot=memchr(line.data,'.',(size_t)(nameEnd-(char *)line.data));
    name=dot ? dot+1 : (char *)line.data;
    for (i=0;i<count;i++) {
      const RCResourceEdit *edit=&edits[i];
      size_t gLen=dot ? (size_t)(dot-(char *)line.data) : 0;
      if (edit->component!=stack[depth-1] || edit->occurrence==-1 ||
          strlen(edit->property)!=(size_t)(nameEnd-name) || strncasecmp(edit->property,name,(size_t)(nameEnd-name)) ||
          (edit->group ? strlen(edit->group) : 0)!=gLen ||
          (gLen && strncasecmp(edit->group,(char *)line.data,gLen))) continue;
      if (patches[i].seen++ != edit->occurrence) continue;
      editIndex=i; reason="property is not writable in this component";
      if (!allowed(kinds[depth-1],edit->property)) goto invalid;
      patches[i].start=start; patches[i].end=pos; patches[i].found=1;
      if (edit->value && !folded(&patches[i].replacement,(char *)line.data,
          (size_t)(sep-(char *)line.data)+1,edit->value)) goto memory;
    }
  }
  editIndex=(size_t)-1; reason="unclosed component";
  if (depth || !closed) goto invalid;
  for(i=0;i<count;i++) if (!patches[i].found) {
    editIndex=i; reason="target component/property occurrence was not found"; goto invalid;
  }
  /* Stable insertion sort preserves caller order for appends at the same END. */
  for(i=1;i<count;i++) {
    Patch p=patches[i]; size_t j=i;
    while(j && patches[j-1].start>p.start) { patches[j]=patches[j-1]; j--; }
    patches[j]=p;
  }
  for(i=0;i<count;i++) {
    if (patches[i].start<cursor) {
      editIndex=(size_t)-1; reason="overlapping edits target the same property"; goto invalid;
    }
    if (!add(&result,base+cursor,patches[i].start-cursor) ||
        !add(&result,patches[i].replacement.data,patches[i].replacement.length)) goto memory;
    cursor=patches[i].end;
  }
  if (!add(&result,base+cursor,length-cursor)) goto memory;
  if (!valid(format,result.data,result.length,e)) goto done;
  *output=result.data; *outputLength=result.length; result.data=NULL; ok=1; goto done;
invalid:
  if (editIndex<count)
    RCErrorSet(e,1,"Resource patch edit %lu (component %lu, property %.64s, occurrence %d): %s",
        (unsigned long)editIndex,(unsigned long)edits[editIndex].component,
        edits[editIndex].property && token(edits[editIndex].property) ? edits[editIndex].property : "<invalid>",
        edits[editIndex].occurrence,reason);
  else RCErrorSet(e,1,"Resource patch: %s",reason);
  goto done;
memory:
  RCErrorSet(e,1,"Out of memory applying resource edits");
done:
  if (patches) for(i=0;i<count;i++) free(patches[i].replacement.data);
  free(patches); free(line.data); free(result.data); return ok;
}

int RCResourceEnqueueEdits(RCWriteJournal *j, const char *change, const char *key,
    long long revision, RCResourceFormat format, const RCResourceEdit *edits,
    size_t count, long long *id, RCError *e)
{
  sqlite3_stmt *q=NULL;
  unsigned char *patched=NULL;
  char *href=NULL;
  size_t length=0;
  int ok=0;
  *id=0;
  /* Prefer an existing operation's immutable base for idempotent replay even
     after subsequent imports have advanced the current publication base. */
  if (sqlite3_prepare_v2(j->db,
      "SELECT href,base_body,local_revision,resource_key FROM write_operations WHERE account_id=? AND change_id=? "
      "UNION ALL SELECT href,body,local_revision,resource_key FROM write_bases WHERE account_id=?1 AND resource_key=?3 "
      "AND NOT EXISTS(SELECT 1 FROM write_operations WHERE account_id=?1 AND change_id=?2) LIMIT 1",
      -1,&q,NULL)!=SQLITE_OK) goto sqlError;
  sqlite3_bind_int64(q,1,j->account); sqlite3_bind_text(q,2,change,-1,SQLITE_TRANSIENT);
  sqlite3_bind_text(q,3,key,-1,SQLITE_TRANSIENT);
  if (sqlite3_step(q)!=SQLITE_ROW || !key ||
      strcmp(key,(const char *)sqlite3_column_text(q,3)) ||
      sqlite3_column_int64(q,2)!=revision) {
    RCErrorSet(e,1,"No matching published revision for local edits"); goto done;
  }
  href=strdup((const char *)sqlite3_column_text(q,0));
  if (!href) { RCErrorSet(e,1,"Out of memory copying published href"); goto done; }
  if (!RCResourcePatch(format,sqlite3_column_blob(q,1),(size_t)sqlite3_column_bytes(q,1),
      edits,count,&patched,&length,e)) goto done;
  sqlite3_finalize(q); q=NULL;
  ok=RCWriteJournalEnqueue(j,change,key,href,"update",revision,patched,length,id,e);
  goto done;
sqlError:
  RCErrorSet(e,1,"Could not read published write base: %s",sqlite3_errmsg(j->db));
done:
  sqlite3_finalize(q); free(href); free(patched); return ok;
}
