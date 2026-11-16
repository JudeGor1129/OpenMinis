#define _POSIX_C_SOURCE 200809L
#include "RootCommandProcess.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static const char *selfPath;
static int childMode(const char *mode) { if (!strcmp(mode,"output")){write(1,"abc",3);write(2,"ERR!",4);return 7;} if(!strcmp(mode,"large")){char b[4096];memset(b,'A',sizeof b);for(int i=0;i<40;i++)if(write(1,b,sizeof b)<0)return 9;return 0;} if(!strcmp(mode,"wait"))for(;;)pause(); if(!strcmp(mode,"descendant")){pid_t p=fork();if(p<0)return 8;if(!p)for(;;)pause();return 0;}return 99;}
static void *revokeLater(void *opaque){struct timespec t={0,150000000};nanosleep(&t,NULL);MRChildRevoke((MinisRootChildControl *)opaque);return NULL;}
static MinisRootChildResult runChild(const char *mode,unsigned timeoutMS,int revoke){MinisRootChildControl *c=calloc(1,sizeof*c);pthread_mutex_init(&c->lock,NULL);pthread_t thread;if(revoke)pthread_create(&thread,NULL,revokeLater,c);char *argv[]={(char*)selfPath,(char*)mode,NULL};MinisRootChildResult r=MRRunChild(selfPath,argv,timeoutMS,c);if(revoke)pthread_join(thread,NULL);pthread_mutex_destroy(&c->lock);free(c);return r;}
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(int argc,char **argv){if(argc==2)return childMode(argv[1]);char resolved[4096];REQUIRE(realpath(argv[0],resolved));selfPath=resolved;MinisRootChildResult r=runChild("output",2000,0);REQUIRE(!r.spawnError&&!r.waitError&&r.exitCode==7&&r.outSize==3&&r.errSize==4);REQUIRE(!memcmp(r.out,"abc",3)&&!memcmp(r.err,"ERR!",4));MRChildFree(&r);puts("PASS root output channels and exit status");r=runChild("large",3000,0);REQUIRE(!r.spawnError&&!r.waitError&&r.exitCode==0&&r.truncated&&r.outSize==MINIS_ROOT_OUTPUT_CAP);MRChildFree(&r);puts("PASS root output bound and no deadlock");r=runChild("wait",200,0);REQUIRE(!r.spawnError&&r.timedOut&&!r.cancelled&&r.signal==SIGKILL);MRChildFree(&r);puts("PASS root timeout and reap");r=runChild("wait",2000,1);REQUIRE(!r.spawnError&&r.cancelled&&!r.timedOut&&r.signal==SIGKILL);MRChildFree(&r);puts("PASS root cancellation and reap");r=runChild("descendant",250,0);REQUIRE(!r.spawnError&&r.timedOut);MRChildFree(&r);puts("PASS descendant-held pipe cleanup");return 0;}
