#!/bin/bash
# Guarded Frida regression checks. This NEVER contacts a server or target.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re
root = Path('src/ios')
source = (root/'Diagnostics/FridaCoreBridge.m').read_text()
policy = (root/'Diagnostics/FridaSafetyPolicy.h').read_text()
settings = (root/'Views/Settings/ToolsSettingsView.swift').read_text()
def require(condition, message):
    if not condition: raise SystemExit('FAIL: Frida guard: '+message)
def function(name):
    match = re.search(r'\b'+re.escape(name)+r'\s*\(',source)
    require(match is not None,'missing '+name)
    cursor=match.end(); depth=1
    while cursor<len(source) and depth:
        if source[cursor]=='(': depth+=1
        elif source[cursor]==')': depth-=1
        cursor+=1
    require(depth==0,'unbalanced parameters '+name)
    while cursor<len(source) and source[cursor].isspace(): cursor+=1
    require(cursor<len(source) and source[cursor]=='{','missing body '+name)
    start=cursor+1; cursor=start; depth=1
    while cursor<len(source) and depth:
        if source[cursor]=='{': depth+=1
        elif source[cursor]=='}': depth-=1
        cursor+=1
    require(depth==0,'unbalanced function '+name)
    return source[start:cursor-1]
for name in ('OpenMinisFridaCoreStatus','OpenMinisFridaServerDiagnostics',
             'OpenMinisFridaCoreAvailable','OpenMinisFridaDiagnosticsAvailable',
             'OpenMinisFridaScriptAvailable'):
    body=function(name)
    require(not re.search(r'\b(?:frida_[a-z_]+|socket|connect|sysctl|dlsym)\s*\(',body),
            name+' must not enter SDK, networking or process preflight')
require('NOT PROBED' in function('OpenMinisFridaServerDiagnostics'),'local status must not claim port readiness')
for name in ('OpenMinisFridaServerPreflight','OpenMinisFridaTargetPreflight'):
    require(not re.search(r'\b(?:frida_[a-z_]+|socket|connect)\s*\(',function(name)),name+' itself must be metadata-only')
open_server = function('OpenMinisFridaOpenServer')
require(open_server.index('OpenMinisFridaServerPreflight') < open_server.index('frida_device_manager_new'),'low-level factory needs gate')
for name in ('OpenMinisFridaProcessesAsync','OpenMinisFridaRunScriptAsync'):
    body = function(name)
    require(body.index('OpenMinisFridaServerPreflight') < body.index('OpenMinisFridaInitialize'),'gate must precede init in '+name)
require('OpenMinisFridaSameProcess(&server, &after)' in source,'stable PID identity must be re-checked')
require('KERN_PROCARGS2' not in source,'app must not attempt root argv reads (mobile gets EINVAL)')
require('OpenMinisFridaGrantGuardedVerdict' in source,'root-helper verdict grant required before init')
require('OpenMinisFridaReadGrant()' in source and 'OpenMinisFridaGrantTTLSeconds' in source,'grant must be revalidated with a bounded TTL')
require('grant.pid == server.kp_proc.p_pid' in source and 'grant.startUsec == server.kp_proc.p_starttime.tv_usec' in source,'grant must bind pid AND starttime')
helper = Path('tools/privileged-helper/MinisPrivilegedHelper.m').read_text()
require('frida_verdict' in helper and 'DoFridaVerdict' in helper,'helper must expose the read-only verdict verb')
require('#include "../../src/ios/Diagnostics/FridaSafetyPolicy.h"' in helper,'helper must share the strict pure-C argv policy')
require('FridaSafetyPolicy.h' in helper and 'OpenMinisFridaArgumentsAreGuarded' in helper,'helper must use the same guarded-arguments test')
require('argvBytes' in helper and 'free(argvBytes)' in helper,'helper must never retain or return argv bytes')
require('Emit(result, 0);' in helper,'verdict action must return a normal envelope')
require('FridaLaunchJobEvidence' in helper,'helper must verify the reviewed launch job when argv is hidden')
require('OPENMINIS_FRIDA_JOB_PLIST "/var/jb/Library/LaunchDaemons/re.frida.server.plist"' in helper,'launch job path must be the reviewed one')
require('info.st_uid != 0 || (info.st_mode & 022) != 0' in helper,'launch job must be root-owned and not group/other writable')
require('launch_job_newer_than_process' in helper,'launch job must predate the process it explains')
require('launch_arguments_unproven' in helper,'launch job arguments must be judged by the shared policy')
require('OpenMinisFridaArgumentsAreGuarded((int)declared.count, argv)' in helper,'launchd path must reuse the same guarded-argument policy')
require('result[@"evidence"] = evidence' in helper and 'result[@"ppid"]' in helper,'verdict must name its evidence class and parent pid')
require('the root-owned job file is verified instead' in source,'status text must disclose the launchd-job evidence class')
session_policy = (root/'Diagnostics/SessionSystemAccessPolicy.h').read_text()
require('frida_verdict' in session_policy,'session policy must allowlist the verdict verb')

require('kp_eproc.e_ucred.cr_uid != 0' in source,'server must be root')
require('server.kp_proc.p_starttime.tv_sec <= 0' in source,'redacted identity must be refused')
require('OpenMinisFridaTargetPreflight((pid_t)pid)' in source,'target check must precede attach')
require('e_ucred.cr_uid != getuid()' in source and 'pid == getpid()' in source,'root/system/self targets refused')
require(not re.search(r'\bfrida_(?:device_spawn|device_enable_spawn_gating|session_enable_child_gating|device_manager_enumerate_devices_sync)',source),'no spawn/gating/local enumeration')
require('g_signal_connect_data' in source and '__bridge_retained void *)collector' in source,'callback lifetime must be retained')
require('FridaScript *script, const gchar *message' in source,'correct message callback signature required')
require('GError **errorPointer' in source and '*errorPointer = NULL;' in source,'consuming GErrors must clear owner pointer')
require('frida_session_detach_sync(session, cleanup, &cleanupError)' in source,'detach errors may not be suppressed')
key='agent.tools.frida.guarded.v1.enabled'
require(key in policy and key in settings,'fresh opt-in must be used consistently')
require('case frida = "agent.tools.frida.enabled"' not in settings,'do not silently reuse #272 enabled state')
version=re.search(r'OPENMINIS_FRIDA_CLIENT_VERSION "([^"]+)"',policy).group(1)
probe=Path('scripts/ios15/probe-frida.sh').read_text()
require('VERSION='+version+'\n' in probe,'constant version must match pinned SDK')
print('PASS: local status isolation, fresh opt-in, helper verdict grant, PID/starttime binding, target limits and cleanup contracts.')
print('NOTE: source contracts do not prove runtime permissions, server listener identity or device stability.')
PY
compiler="$(command -v cc || command -v clang || true)"
if [[ -z "$compiler" ]]; then
  if [[ "${1:-}" == "--require-compiler" || "${CI:-}" == "true" ]]; then
    echo 'FAIL: native compiler required for Frida policy tests' >&2; exit 1
  fi
  echo 'SKIP: native C policy execution (compiler unavailable); source checks are not behavior tests.'
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$compiler" -std=c11 -Wall -Wextra -Werror -I src/ios/Diagnostics \
  toolchain-build/scripts/test-frida-safety-policy.c -o "$work/frida-policy"
"$work/frida-policy"
