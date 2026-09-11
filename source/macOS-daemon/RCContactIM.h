/* Address Book's legacy service properties and modern IMPP share one native
   relationship. Paths count all IM properties in immutable source order. */
static NSString *RCLegacyIMService(const char *name)
{
  const char *names[]={"X-AIM","X-JABBER","X-MSN","X-YAHOO","X-ICQ"};
  NSString *services[]={@"aim",@"jabber",@"msn",@"yahoo",@"icq"}; int i;
  for(i=0;i<5;i++) if(!strcasecmp(name,names[i])) return services[i]; return nil;
}
static NSString *RCContactPathName(const char *name)
{
  return RCLegacyIMService(name) ? @"IMPP" : [[NSString stringWithUTF8String:name] uppercaseString];
}
static BOOL RCContactPropertyVisible(RCVCardProperty *p)
{
  NSString *name=RCContactPathName(p->name), *value=p->decodedValue ? [NSString stringWithUTF8String:p->decodedValue] : @"";
  if([name isEqual:@"ADR"]) return YES;
  if(![value length]) return NO;
  if([name isEqual:@"URL"]) return [NSURL URLWithString:value]!=nil;
  if([name isEqual:@"X-ABDATE"]) {
    int y,m,d; char extra;
    return sscanf(p->decodedValue,"%d-%d-%d%c",&y,&m,&d,&extra)==3 && y>0 && m>0 && m<=12 && d>0 && d<=31;
  }
  if([name isEqual:@"IMPP"]) {
    if(RCLegacyIMService(p->name)) return YES;
    NSRange colon=[value rangeOfString:@":"]; if(colon.location==NSNotFound) return NO;
    NSString *service=[[value substringToIndex:colon.location] lowercaseString];
    return [[@"aim|xmpp|jabber|msn|yahoo|icq" componentsSeparatedByString:@"|"] containsObject:service] &&
        [[[value substringFromIndex:colon.location+1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] length]>0;
  }
  return YES;
}
