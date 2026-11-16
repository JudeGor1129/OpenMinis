#ifndef MINIS_PLUGIN_ARCHIVE_POLICY_H
#define MINIS_PLUGIN_ARCHIVE_POLICY_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <sys/types.h>
#define MINIS_ROOT_FILE_LIMIT (32u * 1024u * 1024u)
#define MINIS_PLUGIN_EXPANSION_LIMIT (48u * 1024u * 1024u)
typedef struct { char package[129], version[65], architecture[33]; unsigned files; } MinisPluginInfo;
static inline int MRPrefix(const char *p, const char *root) {
    size_t n=strlen(root); return !strncmp(p,root,n) && (p[n]==0 || p[n]=='/');
}
static inline int MRSafeRelative(const char *p) {
    if (!p || !*p || *p=='/' || strlen(p)>240) return 0;
    const char *s=p;
    for (const char *q=p;;q++) {
        unsigned char c=(unsigned char)*q;
        if (c && (c<32 || c>126 || c=='\\')) return 0;
        if (!c || c=='/') {
            size_t n=(size_t)(q-s);
            if (!n || (n==1 && *s=='.') || (n==2 && s[0]=='.' && s[1]=='.')) return 0;
            if (!c) break;
            s = q + 1;
        }
    }
    return 1;
}
static inline int MRPackageID(const char *p) {
    if (!p || strlen(p)<2 || strlen(p)>128 || *p=='-') return 0;
    for (;*p;p++) if (!((*p>='a'&&*p<='z')||(*p>='0'&&*p<='9')||strchr("+.-",*p))) return 0;
    return 1;
}
static inline int MRManagedLabel(const char *p,int expert) {
    if (!MRPackageID(p) || strlen(p)>160) return 0;
    if (!expert && strncmp(p,"com.judegor.",12) && strncmp(p,"com.openminis.",14)) return 0;
    return 1;
}
static inline int MRPayloadAllowed(const char *path) {
    const char *roots[]={"var/jb/Library/MobileSubstrate/DynamicLibraries","var/jb/Library/PreferenceBundles",
        "var/jb/Library/PreferenceLoader","var/jb/Library/MinisPet","var/jb/Library/Themes",NULL};
    for (int i=0;roots[i];i++) if (MRPrefix(path,roots[i])) return 1;
    return 0;
}
static inline int MROctal(const unsigned char *p,size_t n,size_t *out) {
    size_t value=0; int digits=0;
    for (size_t i=0;i<n;i++) {
        unsigned c=p[i];
        if (c==0||c==' ') { if (digits) { for (;i<n;i++) if(p[i] && p[i]!=' ') return 0; break; } continue; }
        if (c<'0'||c>'7'||value>(SIZE_MAX-7)/8) return 0;
        value=value*8+(c-'0'); digits=1;
    }
    *out=value; return 1;
}
static inline int MRField(MinisPluginInfo *info,const unsigned char *d,size_t n) {
    if (!n || n>16384 || memchr(d,0,n)) return 0;
    char text[16385]; memcpy(text,d,n); text[n]=0;
    char *save=NULL;
    for (char *line=strtok_r(text,"\n",&save);line;line=strtok_r(NULL,"\n",&save)) {
        char *colon=strchr(line,':'); if(!colon) return 0;
        *colon=0; char *v=colon+1; while(*v==' '||*v=='\t') v++;
        size_t len=strlen(v); if(len && v[len-1]=='\r') v[--len]=0;
        char *target=NULL; size_t cap=0;
        if(!strcmp(line,"Package")) { target=info->package; cap=sizeof(info->package); }
        else if(!strcmp(line,"Version")) { target=info->version; cap=sizeof(info->version); }
        else if(!strcmp(line,"Architecture")) { target=info->architecture; cap=sizeof(info->architecture); }
        else if(!strcmp(line,"Essential") && !strcmp(v,"yes")) return 0;
        else if(!strcmp(line,"Replaces") || !strcmp(line,"Pre-Depends")) return 0;
        if(target) { if(!len||len>=cap||target[0])return 0; memcpy(target,v,len+1); }
    }
    if(!MRPackageID(info->package)||!info->version[0]||strcmp(info->architecture,"iphoneos-arm64"))return 0;
    const char *v=info->version; if(*v<'0'||*v>'9')return 0;
    for(;*v;v++) if(!((*v>='a'&&*v<='z')||(*v>='A'&&*v<='Z')||(*v>='0'&&*v<='9')||strchr(".+~_-",*v)))return 0;
    return 1;
}
static inline int MRDecimal(const unsigned char *p,size_t n,size_t *out) {
    size_t v=0; int seen=0;
    for(size_t i=0;i<n;i++) { unsigned c=p[i]; if(c==0||c==' ') { if(seen) { for(;i<n;i++)if(p[i]&&p[i]!=' ')return 0; break; } continue; }
        if(c<'0'||c>'9'||v>(SIZE_MAX-9)/10)return 0;
        v=v*10+(c-'0'); seen=1; }
    *out=v; return 1;
}
static inline int MRMode(const unsigned char *p,size_t n,size_t *out) {
    size_t v=0; int seen=0;
    for(size_t i=0;i<n;i++) { unsigned c=p[i]; if(c==0||c==' ') { if(seen) { for(;i<n;i++)if(p[i]&&p[i]!=' ')return 0; break; } continue; }
        if(c<'0'||c>'7'||v>(SIZE_MAX-7)/8)return 0;
        v=v*8+(c-'0'); seen=1; }
    *out=v; return 1;
}
static inline int MRControlTar(const unsigned char *tar,size_t total,MinisPluginInfo *info) {
    size_t p=0; int files=0;
    while(p+512<=total) {
        const unsigned char *h=tar+p; if(!h[0]) { for(size_t i=p;i<total;i++)if(tar[i])return 0; return files==1; }
        if(memcmp(h+257,"ustar",5)!=0)return 0;
        size_t size=0,mode=0,uid=0,gid=0; if(!MRMode(h+124,12,&size)||!MRMode(h+100,8,&mode)||!MRMode(h+108,8,&uid)||!MRMode(h+116,8,&gid))return 0;
        if(uid||gid||(mode&07000)||h[156]!='0')return 0;
        char name[101]; memcpy(name,h,100); name[100]=0; if(strcmp(name,"control")||size>16384||p+512+size>total)return 0;
        if(!MRField(info,h+512,size))return 0;
        files++;
        p+=512+((size+511)/512)*512;
    }
    return 0;
}
static inline int MRPayloadTar(const unsigned char *tar,size_t total,MinisPluginInfo *info) {
    size_t p=0,totalBytes=0; unsigned entries=0;
    char **seen=calloc(4096,sizeof(char*)); if(!seen)return 0; int ok=0;
    while(p+512<=total) {
        const unsigned char *h=tar+p; if(!h[0]) { for(size_t i=p;i<total;i++)if(tar[i])goto done; ok=info->files>0; goto done; }
        if(++entries>4096||memcmp(h+257,"ustar",5)!=0)goto done;
        size_t size=0,mode=0,uid=0,gid=0,stored=0; if(!MRMode(h+124,12,&size)||!MRMode(h+100,8,&mode)||!MRMode(h+108,8,&uid)||!MRMode(h+116,8,&gid)||!MRMode(h+148,8,&stored))goto done;
        size_t sum=0; for(unsigned i=0;i<512;i++)sum+=i>=148&&i<156?32:h[i]; if(sum!=stored||uid||gid||(mode&07000)||size>total-p-512||size>MINIS_PLUGIN_EXPANSION_LIMIT-totalBytes)goto done;
        char name[101]; memcpy(name,h,100);name[100]=0;
        char prefix[156]; memcpy(prefix,h+345,155);prefix[155]=0;
        char full[257];
        if(prefix[0]) { if(snprintf(full,sizeof(full),"%s/%s",prefix,name)<0)goto done; }
        else { if(snprintf(full,sizeof(full),"%s",name)<0)goto done; }
        size_t len=strlen(full); if(len&&full[len-1]=='/')full[--len]=0;
        if(!MRSafeRelative(full))goto done;
        for(unsigned i=0;i<entries-1;i++) if(!strcmp(full,seen[i])) goto done;
        seen[entries-1]=strdup(full);
        if(!seen[entries-1])goto done;
        unsigned type=h[156]; if(type!='0'&&type!='5')goto done;
        if(type=='5') { if(size||(mode&0777)!=0755||(!MRPrefix(full,"var/jb")&&strcmp(full,"var")))goto done; }
        else {
            int fileMode = mode & 0777;
            if ((fileMode != 0755 && fileMode != 0644) || !MRPayloadAllowed(full)) goto done;
            info->files++;
            totalBytes += size;
        }
        p+=512+((size+511)/512)*512;
    }
 done: for(unsigned i=0;i<entries&&i<4096;i++)free(seen[i]);free(seen);return ok;
}
static inline int MinisInspectPlugin(const void *input,size_t n,MinisPluginInfo *info) {
    const unsigned char *d=input; memset(info,0,sizeof(*info)); if(n<8||n>MINIS_ROOT_FILE_LIMIT||memcmp(d,"!<arch>\n",8))return 0;
    size_t p=8; int members=0; while(p+60<=n) {
        const unsigned char *h=d+p; if(memcmp(h+58,"`\n",2))return 0; char name[17];memcpy(name,h,16);name[16]=0;size_t l=strlen(name);while(l&&(name[l-1]==' '||name[l-1]=='/'))name[--l]=0;
        size_t size=0;if(!MRDecimal(h+48,10,&size)||p+60+size>n)return 0;const unsigned char *body=h+60;
        if(members==0){if(strcmp(name,"debian-binary")||size!=4||memcmp(body,"2.0\n",4))return 0;}
        else if(members==1){if(strcmp(name,"control.tar")||!MRControlTar(body,size,info))return 0;}
        else if(members==2){if(strcmp(name,"data.tar")||!MRPayloadTar(body,size,info))return 0;}
        else return 0;
        p+=60+size+(size&1);members++;
    }
    return members==3&&p==n;
}
#endif
