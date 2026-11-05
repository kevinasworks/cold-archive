// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
#ifndef NATIVE_MONITOR_H
#define NATIVE_MONITOR_H
#include <stdint.h>
typedef struct { char oid[256]; char text[512]; double number; int numeric; } CAMetric;
int ca_snmp(const char *host, int port, int version, const char *user, const char *auth, const char *privacy, int secure, int auth_algorithm, int privacy_algorithm, const char *oid_text, int walk, CAMetric *out, int capacity, char *error, int error_size);
// Callback strings are transient. Only endpoint/interface events contain addresses;
// callers must pseudonymize them. Never carries credentials or packet payloads.
typedef void (*CADiagnostic)(void *context, const char *event, const char *value, int number, int system_error);
int ca_snmp_diagnostic(const char *host, int port, int version, const char *user, const char *auth, const char *privacy, int secure, int auth_algorithm, int privacy_algorithm, const char *oid_text, int walk, CAMetric *out, int capacity, char *error, int error_size, CADiagnostic callback, void *context);
// Call begin/end on the same serial thread with an immutable configuration.
void ca_snmp_batch_begin(void);
void ca_snmp_batch_begin_transport(int tcp);
void ca_snmp_batch_end(void);
int ca_cpu(uint64_t *busy, uint64_t *total);
// Process-local kernel disk accounting, NOT logical reads or SMB traffic.
typedef struct { uint64_t start, cpu_ns, resident, footprint, read_bytes, write_bytes; } CAProcessUsage;
int ca_process_usage(int pid, CAProcessUsage *out);
int ca_process_fd_count(int pid);
int ca_process_children(int pid, int *out, int capacity);
#endif
