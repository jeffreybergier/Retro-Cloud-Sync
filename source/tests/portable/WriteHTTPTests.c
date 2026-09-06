#include "RCHTTPClient.h"
#include <AltivecCore/curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static RCError error;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"HTTP FAIL line %d: %s (%s)\n",__LINE__,#x,error.message); exit(1); } } while(0)
int main(int argc, char **argv)
{
  RCHTTPClientConfig config;
  RCHTTPClient *client;
  RCHTTPResponse response;
  char url[256];
  CHECK(argc==4 && curl_global_init(CURL_GLOBAL_DEFAULT)==CURLE_OK);
  memset(&config,0,sizeof(config)); config.username="test-user"; config.password="synthetic-password";
  config.certificatePath=argv[2]; config.allowedHostSuffix="localhost";
  client=RCHTTPClientCreate(&config,&error); CHECK(client); RCHTTPResponseInit(&response);
  snprintf(url,sizeof(url),"%s/create",argv[1]);
  CHECK(!RCHTTPClientRequest(client,"PUT",url,NULL,"text/vcard","new",3,&response,&error));
  CHECK(!RCHTTPClientConditionalRequest(client,"PUT",url,"text/vcard","new",3,"\"bad\r\nInjected: yes\"",0,&response,&error));
  CHECK(!RCHTTPClientConditionalRequest(client,"PUT",url,"text/vcard","new",3,"W/\"weak\"",0,&response,&error));
  CHECK(RCHTTPClientConditionalRequest(client,"PUT",url,"text/vcard","new",3,NULL,1,&response,&error) && response.statusCode==201);
  snprintf(url,sizeof(url),"%s/update",argv[1]);
  CHECK(RCHTTPClientConditionalRequest(client,"PUT",url,"text/vcard","edit",4,"\"base\"",0,&response,&error) && response.statusCode==204);
  snprintf(url,sizeof(url),"%s/delete",argv[1]);
  CHECK(!RCHTTPClientConditionalRequest(client,"DELETE",url,NULL,NULL,0,NULL,1,&response,&error));
  CHECK(RCHTTPClientConditionalRequest(client,"DELETE",url,NULL,NULL,0,"\"base\"",0,&response,&error) && response.statusCode==204);
  snprintf(url,sizeof(url),"%s/move",argv[1]);
  CHECK(RCHTTPClientConditionalRequest(client,"PUT",url,"text/vcard","new",3,NULL,1,&response,&error) && response.statusCode==307);
  CHECK(response.effectiveURL && !strcmp(response.effectiveURL,url));
  snprintf(url,sizeof(url),"%s/discovery",argv[1]);
  CHECK(RCHTTPClientRequest(client,"PROPFIND",url,"0","application/xml","<probe/>",8,&response,&error) && response.statusCode==207);
  snprintf(url,sizeof(url),"%s/foreign",argv[1]);
  CHECK(!RCHTTPClientRequest(client,"GET",url,NULL,NULL,NULL,0,&response,&error));
  RCHTTPClientDestroy(client);
  config.allowedHostSuffix=NULL; client=RCHTTPClientCreate(&config,&error); CHECK(client);
  snprintf(url,sizeof(url),"https://127.0.0.1%s/update",strrchr(argv[1],':'));
  CHECK(!RCHTTPClientRequest(client,"GET",url,NULL,NULL,NULL,0,&response,&error));
  RCHTTPClientDestroy(client);
  config.certificatePath=argv[3]; client=RCHTTPClientCreate(&config,&error); CHECK(client);
  snprintf(url,sizeof(url),"%s/update",argv[1]);
  CHECK(!RCHTTPClientRequest(client,"GET",url,NULL,NULL,NULL,0,&response,&error));
  RCHTTPClientDestroy(client); RCHTTPResponseClear(&response); curl_global_cleanup();
  puts("Production HTTP conditional headers, redirect boundaries and TLS rejection tests passed.");
  return 0;
}
