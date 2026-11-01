#!/usr/bin/env python3
"""Validate reviewed fixed-fixture device evidence against the pinned toolchain.

The source report is user-supplied and not cryptographically device-signed.
Passing authorizes OM_TOOLCHAIN_VERIFIED only in the disposable validation
App. It does not enable EmbeddedToolchainBuildProvider.
"""
import argparse, json, re
from pathlib import Path

REQUIRED_STEPS = {
    "compile_arm64_c": "ok", "link_arm64_dylib": "ok",
    "compile_arm64e_c": "ok", "link_arm64e_dylib": "ok",
    "link_probe_full_dylib": "ok", "link_probe_libsystem_dylib": "ok",
    "compile_arm64_objective_c": "ok", "compile_arm64_foundation_objective_c": "ok",
    "expected_clang_failure": "diagnostics_expected", "clang_recovery_after_failure": "ok",
    "expected_linker_failure": "diagnostics_expected", "linker_recovery_after_failure": "ok",
    "repeat_compile_link_1": "ok", "repeat_compile_link_2": "ok", "repeat_compile_link_3": "ok",
}
EXPECTED_NEGATIVE = {"link_probe_minimal_dylib", "link_probe_platform_version", "link_probe_install_name", "link_probe_executable"}

def fail(message):
    raise SystemExit("runtime evidence verification failed: " + message)

def load(path):
    try: return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error: fail(f"cannot read {path}: {error}")

def require_sha(value, label):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None: fail(f"invalid SHA-256 for {label}")

def main():
    p=argparse.ArgumentParser(); p.add_argument("evidence",type=Path); p.add_argument("lock",type=Path); a=p.parse_args()
    e,l=load(a.evidence),load(a.lock)
    if e.get("schema")!=1 or e.get("evidence_kind")!="fixed_runtime_fixtures": fail("unexpected evidence schema/kind")
    if e.get("provenance")!="user-supplied device report; not cryptographically device-signed": fail("evidence provenance must remain explicit")
    require_sha(e.get("report_sha256"),"device report")
    app,kit=e.get("app",{}),e.get("toolchain",{}); art=l.get("artifact",{}); mf=l.get("manifest",{})
    pairs=((kit.get("workflow_run_id"),l.get("workflow_run_id"),"toolchain run"),(kit.get("commit"),l.get("head_sha"),"toolchain commit"),(kit.get("artifact_id"),art.get("id"),"toolchain artifact ID"),(kit.get("archive_sha256"),art.get("archive_sha256"),"toolchain ZIP hash"),(kit.get("manifest_sha256"),mf.get("sha256"),"toolchain manifest hash"))
    for actual,expected,label in pairs:
        if actual!=expected: fail(f"evidence does not match locked {label}")
    if type(app.get("workflow_run_id")) is not int or type(app.get("artifact_id")) is not int: fail("App run/artifact IDs missing")
    if re.fullmatch(r"[0-9a-f]{40}",app.get("commit","")) is None: fail("invalid App commit")
    require_sha(app.get("artifact_sha256"),"App artifact")
    r=e.get("report",{}); expected={"passed":True,"requested_iterations":3,"bounded_iterations":3,"foundation_sdk_compilation":"passed","temporary_outputs_removed":True,"output_execution_attempted":False,"provider_executable":False,"runtime_verification_gate":"not_granted","capability_verification":"missing"}
    for key,value in expected.items():
        if r.get(key)!=value: fail(f"report {key} must be {value!r}")
    steps=r.get("required_steps",{})
    if set(steps)!=set(REQUIRED_STEPS): fail("required step inventory differs")
    for name,value in REQUIRED_STEPS.items():
        if steps.get(name)!=value: fail(f"step {name} must be {value}")
    if set(r.get("expected_negative_probes",[]))!=EXPECTED_NEGATIVE: fail("expected-negative probe inventory differs")
    policy=e.get("policy",{})
    if policy.get("verification_macro_may_be_defined_for_validation_app") is not True: fail("validation-App policy approval missing")
    if policy.get("provider_must_remain_unavailable") is not True: fail("Provider must remain unavailable")
    if policy.get("reason")!="No constrained in-process BuildProvider execution adapter has been implemented or reviewed.": fail("Provider lock reason differs")
    print("PASS: three-round Foundation/runtime evidence matches the pinned Run15 toolchain.")
    print("PASS: only the validation-App macro is authorized; Provider remains unavailable.")
    print("NOTE: report is user-supplied and is not cryptographically device-signed.")

if __name__=="__main__": main()
