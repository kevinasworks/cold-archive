// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
#include "NativeMonitor.h"
#include <net-snmp/net-snmp-config.h>
#include <net-snmp/net-snmp-includes.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/resource.h>
#include <stdlib.h>

int ca_process_fd_count(int pid) {
    int bytes=proc_pidinfo(pid,PROC_PIDLISTFDS,0,NULL,0);
    if(bytes<=0 || bytes>16*1024*1024)return -1;
    int capacity=bytes+64*(int)sizeof(struct proc_fdinfo);
    void *buffer=malloc((size_t)capacity);
    if(!buffer)return -1;
    int actual=proc_pidinfo(pid,PROC_PIDLISTFDS,0,buffer,capacity);
    free(buffer);
    return actual>0 && actual<capacity ? actual/(int)sizeof(struct proc_fdinfo):-1;
}

int ca_process_usage(int pid, CAProcessUsage *out) {
    struct rusage_info_v2 usage={0};
    if(proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t*)&usage)!=0)return -1;
    *out=(CAProcessUsage){usage.ri_proc_start_abstime,
        usage.ri_user_time+usage.ri_system_time,usage.ri_resident_size,
        usage.ri_phys_footprint,usage.ri_diskio_bytesread,usage.ri_diskio_byteswritten};
    return 0;
}
int ca_process_children(int pid,int *out,int capacity) {
    if(capacity<=0)return -1;
    int bytes=proc_listchildpids(pid,out,capacity*(int)sizeof(int));
    return bytes<0 ? -1:bytes/(int)sizeof(int);
}

typedef struct {
    CADiagnostic callback; void *context;
    int (*send)(netsnmp_transport *, void *, int, void **, int *);
    int (*recv)(netsnmp_transport *, void *, int, void **, int *);
} CATrace;
static _Thread_local CATrace trace;
static _Thread_local int use_tcp;
static _Thread_local int received_response;
static void emit(const char *event,const char *value,int number,int error) {
    if(trace.callback)trace.callback(trace.context,event,value,number,error);
}
static const char *library_code(int code) {
    switch(code) {
        case SNMPERR_TIMEOUT:return "timeout";
        case SNMPERR_UNKNOWN_USER_NAME:case SNMPERR_USM_UNKNOWNSECURITYNAME:return "unknown_user";
        case SNMPERR_UNSUPPORTED_SEC_LEVEL:case SNMPERR_USM_UNSUPPORTEDSECURITYLEVEL:return "unsupported_security_level";
        case SNMPERR_AUTHENTICATION_FAILURE:case SNMPERR_USM_AUTHENTICATIONFAILURE:return "authentication_failed";
        case SNMPERR_NOT_IN_TIME_WINDOW:case SNMPERR_USM_NOTINTIMEWINDOW:return "not_in_time_window";
        case SNMPERR_DECRYPTION_ERR:case SNMPERR_USM_DECRYPTIONERROR:return "decryption_failed";
        case SNMPERR_BAD_PARSE:case SNMPERR_ASN_PARSE_ERR:case SNMPERR_USM_PARSEERROR:return "parse_failed";
        case SNMPERR_BAD_SENDTO:return "send_failed";
        case SNMPERR_BAD_RECVFROM:return "receive_failed";
        default:return "native_error";
    }
}
static int traced_send(netsnmp_transport *t,void *b,int n,void **o,int *l) {
    // macOS rejects sendto(destination) on a connected UDP socket.
    // The peer was fixed before session creation; send uses that exact peer.
    int r=use_tcp ? trace.send(t,b,n,o,l):(int)send(t->sock,b,(size_t)n,0), e=r<0?errno:0;
    emit(use_tcp?"tcp_send":"udp_send",r<0?"failed":"accepted_by_local_socket",r,e);errno=e;return r;
}
static int traced_recv(netsnmp_transport *t,void *b,int n,void **o,int *l) {
    int r=trace.recv(t,b,n,o,l), e=r<0?errno:0;
    if(use_tcp && r==0){emit("tcp_eof","peer_closed",0,0);return r;}
    if(r>0)received_response=1;
    emit(use_tcp?"tcp_receive":"udp_receive",r<0?"failed":"received",r,e);errno=e;return r;
}
// Inspect the actual connected SNMP socket, never a separate route probe.
static void route_snapshot(int fd) {
    struct sockaddr_storage local; socklen_t size=sizeof(local);
    if(getsockname(fd,(struct sockaddr*)&local,&size)<0){emit("route_snapshot","local_address_failed",0,errno);return;}
    int family=local.ss_family;
    void *raw=family==AF_INET?(void*)&((struct sockaddr_in*)&local)->sin_addr:(void*)&((struct sockaddr_in6*)&local)->sin6_addr;
    char address[INET6_ADDRSTRLEN];
    if(inet_ntop(family,raw,address,sizeof(address)))emit("source_address",address,family,0);
    struct ifaddrs *interfaces=NULL;int found=0;
    if(getifaddrs(&interfaces)==0){
        for(struct ifaddrs *i=interfaces;i;i=i->ifa_next) {
            if(!i->ifa_addr || i->ifa_addr->sa_family!=family)continue;
            void *other=family==AF_INET?(void*)&((struct sockaddr_in*)i->ifa_addr)->sin_addr:(void*)&((struct sockaddr_in6*)i->ifa_addr)->sin6_addr;
            if(!memcmp(raw,other,family==AF_INET?4:16)){emit("route_interface",i->ifa_name,0,0);found=1;break;}
        }
        freeifaddrs(interfaces);
    }
    emit("route_snapshot",found?"actual_socket":"interface_unknown",0,0);
}
static pthread_mutex_t session_lock=PTHREAD_MUTEX_INITIALIZER;
static _Thread_local int batch;
static _Thread_local void *retained;
static _Thread_local CATrace retained_trace;
// All library users in this application are serialized, including legacy callers.
// Remove only the session's discovered engine/user entry, never unrelated users.
static void close_session(void *handle) {
    netsnmp_session *s=snmp_sess_session(handle);
    struct usmUser *u=s && s->version==SNMP_VERSION_3 && s->securityEngineIDLen ? usm_get_user(s->securityEngineID,s->securityEngineIDLen,s->securityName):NULL;
    snmp_sess_close(handle);
    if(u)usm_free_user(usm_remove_user(u));
}
void ca_snmp_batch_begin(void) {pthread_mutex_lock(&session_lock);batch=1;}
void ca_snmp_batch_begin_transport(int tcp) {ca_snmp_batch_begin();use_tcp=tcp!=0;}
void ca_snmp_batch_end(void) {
    if(retained)close_session(retained);
    retained=NULL;batch=0;use_tcp=0;trace=(CATrace){0};retained_trace=(CATrace){0};pthread_mutex_unlock(&session_lock);
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) {
    netsnmp_ds_set_boolean(NETSNMP_DS_LIBRARY_ID, NETSNMP_DS_LIB_DONT_READ_CONFIGS, 1);
    init_snmp("ColdArchive");
}
int ca_cpu(uint64_t *busy, uint64_t *total) {
    host_cpu_load_info_data_t data; mach_msg_type_number_t n=HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host=mach_host_self();
    kern_return_t r=host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&data, &n);
    mach_port_deallocate(mach_task_self(),host);
    if(r!=KERN_SUCCESS) return -1;
    *busy=(uint64_t)data.cpu_ticks[CPU_STATE_USER]+data.cpu_ticks[CPU_STATE_SYSTEM]+data.cpu_ticks[CPU_STATE_NICE];
    *total=*busy+data.cpu_ticks[CPU_STATE_IDLE]; return 0;
}
static int query_address(const char *host,int port,int version,const char *user,const char *auth,const char *privacy,int secure,int auth_algorithm,int privacy_algorithm,const char *oid_text,int walk,CAMetric *out,int capacity,char *error,int error_size,CADiagnostic callback,void *context) {
    trace=(CATrace){.callback=callback,.context=context};
    pthread_once(&once,initialize);
    void *handle=retained;
    if(handle){trace.send=retained_trace.send;trace.recv=retained_trace.recv;emit("session_reused","same_sample",1,0);}
    else {
    struct addrinfo hints={0},*addresses=NULL;
    hints.ai_family=AF_UNSPEC;hints.ai_socktype=use_tcp?SOCK_STREAM:SOCK_DGRAM;hints.ai_flags=AI_NUMERICHOST;
    char service[16];snprintf(service,sizeof(service),"%d",port);
    if(getaddrinfo(host,service,&hints,&addresses)){snprintf(error,error_size,"SNMP 数字地址无效");return -1;}
    char peer[320];snprintf(peer,sizeof(peer),addresses->ai_family==AF_INET6?(use_tcp?"tcp6:[%s]:%d":"udp6:[%s]:%d"):(use_tcp?"tcp:%s:%d":"udp:%s:%d"),host,port);
    emit("selected_address",host,addresses->ai_family,0);
    netsnmp_session session; snmp_sess_init(&session);
    freeaddrinfo(addresses);
    session.peername=peer; session.timeout=3000000; session.retries=1;
    session.version=version==3?SNMP_VERSION_3:SNMP_VERSION_2c;
    if(version==3) {
        session.securityName=(char*)user; session.securityNameLen=strlen(user);
        session.securityLevel=secure?SNMP_SEC_LEVEL_AUTHPRIV:SNMP_SEC_LEVEL_AUTHNOPRIV;
        session.securityAuthProto=auth_algorithm ? usmHMACMD5AuthProtocol : usmHMACSHA1AuthProtocol; session.securityAuthProtoLen=auth_algorithm ? USM_AUTH_PROTO_MD5_LEN : USM_AUTH_PROTO_SHA_LEN;
        session.securityAuthKeyLen=USM_AUTH_KU_LEN;
        if(generate_Ku(session.securityAuthProto,session.securityAuthProtoLen,(const u_char*)auth,strlen(auth),session.securityAuthKey,&session.securityAuthKeyLen)!=SNMPERR_SUCCESS) {
            snprintf(error,error_size,"SNMPv3 认证密码无效（至少 8 个字符）");return -1;
        }
        if(secure) {
            session.securityPrivProto=privacy_algorithm ? usmDESPrivProtocol : usmAESPrivProtocol;session.securityPrivProtoLen=privacy_algorithm ? USM_PRIV_PROTO_DES_LEN : USM_PRIV_PROTO_AES_LEN;
            session.securityPrivKeyLen=USM_PRIV_KU_LEN;
            if(generate_Ku(session.securityAuthProto,session.securityAuthProtoLen,(const u_char*)privacy,strlen(privacy),session.securityPrivKey,&session.securityPrivKeyLen)!=SNMPERR_SUCCESS) {
                snprintf(error,error_size,"SNMPv3 隐私密码无效（至少 8 个字符）");return -1;
            }
        }
    } else {session.community=(u_char*)auth;session.community_len=strlen(auth);}
    emit("transport_begin",strchr(host,':')?(use_tcp?"tcp6":"udp6"):(use_tcp?"tcp4":"udp4"),0,0);
    netsnmp_transport *transport= netsnmp_transport_open_client("snmp",peer);
    if(!transport){emit("transport_error","open_failed",snmp_errno,errno);snprintf(error,error_size,"SNMP 连接失败：请检查所选 TCP/UDP 协议、端口映射及 NAS 服务监听。");return -1;}
    if(!use_tcp) {
    struct addrinfo *destination=NULL;
    if(getaddrinfo(host,service,&hints,&destination) || connect(transport->sock,destination->ai_addr,(socklen_t)destination->ai_addrlen)<0){
        int e=errno;if(destination)freeaddrinfo(destination);transport->f_close(transport);netsnmp_transport_free(transport);
        emit("transport_error","connect_failed",0,e);snprintf(error,error_size,"SNMP UDP socket 连接失败（系统错误 %d）",e);return -1;
    }
    freeaddrinfo(destination);
    }
    route_snapshot(transport->sock);
    trace.send=transport->f_send;trace.recv=transport->f_recv;
    transport->f_send=traced_send;transport->f_recv=traced_recv;
    emit("session_begin",version==3?"v3_engine_discovery":"v2c",0,0);
    handle=snmp_sess_add(&session,transport,NULL,NULL);
    if(!handle){
        int lib=0,sys=0;char *detail=NULL;snmp_error(&session,&sys,&lib,&detail);
        emit("session_error",library_code(lib),lib,sys);free(detail);
        snprintf(error,error_size,"无法建立 SNMP 会话（库错误 %d，系统错误 %d）",lib,sys);return -1;
    }
    emit("session_ready","engine_id_available",snmp_sess_session(handle)->securityEngineIDLen>0,0);
    }
    oid root[MAX_OID_LEN];size_t rootlen=MAX_OID_LEN;
    if(!snmp_parse_oid(oid_text,root,&rootlen)){close_session(handle);retained=NULL;snprintf(error,error_size,"指标 OID 无效");return -1;}
    oid cursor[MAX_OID_LEN];size_t cursorlen=rootlen;memcpy(cursor,root,rootlen*sizeof(oid));
    int count=0,done=0;
    // Continue until the subtree ends; neither a short page nor the output
    // buffer filling is proof of completion. Reject truncated/non-progressing walks.
    for(int page=0;!done;page++) {
    if(page>=128){emit("walk_error","page_limit",page,0);snprintf(error,error_size,"SNMP 遍历超过页数限制，结果不完整");count=-1;break;}
    netsnmp_pdu *request=snmp_pdu_create(walk?SNMP_MSG_GETBULK:SNMP_MSG_GET);
    if(walk){request->non_repeaters=0;request->max_repetitions=32;}
    snmp_add_null_var(request,cursor,cursorlen);
    netsnmp_pdu *response=NULL;
    unsigned int before[6];for(int i=0;i<6;i++)before[i]=snmp_get_statistic(STAT_USM_STATS_START+i);
    emit("query_begin","request",0,0);
    int status=snmp_sess_synch_response(handle,request,&response);
    int previous_count=count;
    emit("query_status","native_status",status,0);
    emit("engine_state","engine_id_available",snmp_sess_session(handle)->securityEngineIDLen>0,0);
    const char *usm_names[]={"unsupported_security_level","not_in_time_window","unknown_user","unknown_engine","wrong_digest","decryption_error"};
    for(int i=0;i<6;i++) {unsigned int delta=snmp_get_statistic(STAT_USM_STATS_START+i)-before[i];if(delta)emit("local_usm_counter",usm_names[i],(int)delta,0);}
    if(response) {
        emit("pdu_response","command",response->command,0);
        if(response->errstat)emit("pdu_error","agent_error",(int)response->errstat,0);
        if(response->command==SNMP_MSG_REPORT && response->variables) {
            // Persist only the known USM report index, never arbitrary OIDs/values.
            oid prefix[]={1,3,6,1,6,3,15,1,1};netsnmp_variable_list *v=response->variables;
            if(v->name_length==11 && !memcmp(v->name,prefix,sizeof(prefix)) && v->name[10]==0 && v->name[9]>=1 && v->name[9]<=6)
                emit("usm_report","counter_index",(int)v->name[9],0);
        }
    }
    if(status!=STAT_SUCCESS || !response || response->errstat || response->command==SNMP_MSG_REPORT) {
        if(status==STAT_TIMEOUT) snprintf(error,error_size,"SNMP 请求超时：检查所选传输协议的端口、网络路径及 DSM 服务；超时也可能由认证配置不匹配导致");
        else if(response && response->command==SNMP_MSG_REPORT) snprintf(error,error_size,"SNMPv3 代理拒绝请求：请检查用户名、认证协议、密码及隐私开关（REPORT）");
        else if(response && response->errstat) snprintf(error,error_size,"SNMP 代理返回错误 %ld：%s",response->errstat,snmp_errstring(response->errstat));
        else { int liberr=0,syserr=0;char *detail=NULL;snmp_sess_error(handle,&syserr,&liberr,&detail);const char *code=library_code(liberr);
            const char *message=!strcmp(code,"timeout") ? "NAS 未响应 SNMP 请求：请检查该地址的 SNMP 端口是否可达，并核对 DSM 的 SNMP 配置。"
                :!strcmp(code,"unsupported_security_level") ? "SNMP 加密设置不匹配：请让软件的隐私开关与 DSM 保持一致。"
                :!strcmp(code,"unknown_user") ? "NAS 不识别此 SNMP 用户：请核对 DSM 中配置的 SNMPv3 用户名。"
                :!strcmp(code,"authentication_failed") ? "SNMP 认证失败：请核对认证协议和认证密码。"
                :!strcmp(code,"decryption_failed") ? "SNMP 解密失败：请核对隐私协议和隐私密码。"
                :!strcmp(code,"send_failed") ? "SNMP 请求未能发出：请检查网络连接；具体系统错误已记录到诊断日志。"
                :"SNMP 通信失败：请检查连接及 DSM 配置；具体错误已记录到诊断日志。";
            snprintf(error,error_size,"%s",message);if(detail)free(detail); }
        int lib=0,sys=0;char *detail=NULL;snmp_sess_error(handle,&sys,&lib,&detail);
        emit("query_error",library_code(lib),lib,sys);free(detail);
        count=-1;done=1;
    } else for(netsnmp_variable_list *v=response->variables;v;v=v->next_variable) {
        if(v->type==SNMP_NOSUCHOBJECT||v->type==SNMP_NOSUCHINSTANCE||v->type==SNMP_ENDOFMIBVIEW){
            emit("binding_exception",v->type==SNMP_NOSUCHOBJECT ? "no_such_object":v->type==SNMP_NOSUCHINSTANCE ? "no_such_instance":"end_of_mib",v->type,0);done=1;break;
        }
        if(walk&&(v->name_length<rootlen||memcmp(root,v->name,rootlen*sizeof(oid)))){emit("walk_end","outside_subtree",0,0);done=1;break;}
        if(walk && snmp_oid_compare(v->name,v->name_length,cursor,cursorlen)<=0){emit("walk_error","non_increasing_oid",0,0);snprintf(error,error_size,"SNMP 遍历返回重复或倒退 OID，结果不完整");count=-1;done=1;break;}
        if(count>=capacity){emit("walk_error","capacity_limit",capacity,0);snprintf(error,error_size,"SNMP 指标超过容量限制，结果不完整");count=-1;done=1;break;}
        memcpy(cursor,v->name,v->name_length*sizeof(oid));cursorlen=v->name_length;
        CAMetric *m=&out[count++];memset(m,0,sizeof(*m));
        size_t used=0;for(size_t i=0;i<v->name_length&&used<sizeof(m->oid)-24;i++)used+=snprintf(m->oid+used,sizeof(m->oid)-used,"%s%lu",i?".":"",v->name[i]);
        if(v->type==ASN_OCTET_STR){size_t n=v->val_len<sizeof(m->text)-1?v->val_len:sizeof(m->text)-1;memcpy(m->text,v->val.string,n);}
        else if(v->type==ASN_COUNTER64){m->number=(double)v->val.counter64->high*4294967296.0+v->val.counter64->low;m->numeric=1;}
        else if(v->type==ASN_INTEGER||v->type==ASN_COUNTER||v->type==ASN_GAUGE||v->type==ASN_TIMETICKS){m->number=(double)*v->val.integer;m->numeric=1;}
    }
    if(response)snmp_free_pdu(response);
    if(!walk)done=1;
    if(walk && !done && count==previous_count){emit("walk_error","empty_page",0,0);snprintf(error,error_size,"SNMP 遍历返回空页，无法确认完整性");count=-1;done=1;}
    }
    if(batch && (count>=0 || retained==handle)){retained=handle;retained_trace=trace;}
    else {close_session(handle);retained=NULL;}
    return count;
}

int ca_snmp_diagnostic(const char *host,int port,int version,const char *user,const char *auth,const char *privacy,int secure,int auth_algorithm,int privacy_algorithm,const char *oid_text,int walk,CAMetric *out,int capacity,char *error,int error_size,CADiagnostic callback,void *context) {
    if(!batch)pthread_mutex_lock(&session_lock);
    trace=(CATrace){.callback=callback,.context=context};
    int result=-1;
    if(retained){
        result=query_address(host,port,version,user,auth,privacy,secure,auth_algorithm,privacy_algorithm,oid_text,walk,out,capacity,error,error_size,callback,context);
    } else {
        emit("dns_begin","dual_stack",0,0);
        struct addrinfo hints={0},*addresses=NULL;hints.ai_family=AF_UNSPEC;hints.ai_socktype=use_tcp?SOCK_STREAM:SOCK_DGRAM;
        char service[16];snprintf(service,sizeof(service),"%d",port);
        int gai=getaddrinfo(host,service,&hints,&addresses);
        if(gai){emit("dns_end","failed",gai,gai==EAI_SYSTEM?errno:0);snprintf(error,error_size,"NAS 地址解析失败（解析错误 %d）",gai);}
        else {
            int count=0;for(struct addrinfo *a=addresses;a;a=a->ai_next)count++;
            emit("dns_end","success",count,0);
            int attempt=0;
            for(struct addrinfo *a=addresses;a;a=a->ai_next){
                char ip[NI_MAXHOST];if(getnameinfo(a->ai_addr,(socklen_t)a->ai_addrlen,ip,sizeof(ip),NULL,0,NI_NUMERICHOST))continue;
                emit("dns_address",ip,a->ai_family,0);emit("candidate_attempt","same_security_configuration",++attempt,0);
                received_response=0;
                result=query_address(ip,port,version,user,auth,privacy,secure,auth_algorithm,privacy_algorithm,oid_text,walk,out,capacity,error,error_size,callback,context);
                if(result>=0 || received_response)break; // Never try another endpoint after an agent has responded.
            }
            freeaddrinfo(addresses);
        }
    }
    trace=(CATrace){0};
    if(!batch)pthread_mutex_unlock(&session_lock);
    return result;
}

int ca_snmp(const char *host,int port,int version,const char *user,const char *auth,const char *privacy,int secure,int auth_algorithm,int privacy_algorithm,const char *oid_text,int walk,CAMetric *out,int capacity,char *error,int error_size) {
    return ca_snmp_diagnostic(host,port,version,user,auth,privacy,secure,auth_algorithm,privacy_algorithm,oid_text,walk,out,capacity,error,error_size,NULL,NULL);
}
