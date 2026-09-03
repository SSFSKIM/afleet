import json, subprocess, sys, uuid, time, threading, os
cwd=sys.argv[1]
def run(extra_env, steps, label):
    env=dict(os.environ); env.update(extra_env)
    cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--replay-user-messages","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
    p=subprocess.Popen(cmd,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,env=env)
    frames=[]; lock=threading.Lock()
    def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
    def reader():
        for line in p.stdout:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except: continue
            with lock: frames.append(m)
            if m.get("type")=="control_request" and (m.get("request") or {}).get("subtype")=="can_use_tool":
                send({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{"behavior":"allow","updatedInput":m["request"]["input"]}}})
    threading.Thread(target=reader,daemon=True).start()
    def ctl(sub,**kw):
        r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":sub,**kw}}); return r
    def wait_ctl(r,timeout=30):
        t=time.time()
        while time.time()-t<timeout:
            with lock:
                for f in frames:
                    if f.get("type")=="control_response" and (f.get("response") or {}).get("request_id")==r: return f["response"]
            time.sleep(0.2)
    print(f"===== {label}")
    r=wait_ctl(ctl("initialize",supportedDialogKinds=[]))
    body=(r or {}).get("response") or {}
    print("init fast_mode_state:", body.get("fast_mode_state"), body.get("fast_mode_disabled_reason"))
    for kind,val in steps:
        if kind=="ctl":
            sub,kw=val; rr=wait_ctl(ctl(sub,**kw)); print(f"  ctl {sub} {json.dumps(kw)} → {json.dumps(rr.get('response') if rr.get('subtype')=='success' else rr.get('error'))[:200]}")
        else:
            start=len(frames)
            send({"type":"user","uuid":str(uuid.uuid4()),"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":val}})
            t=time.time()
            while time.time()-t<90:
                with lock: fr=frames[start:]
                if any(f.get("type")=="result" for f in fr): break
                time.sleep(0.2)
            with lock: fr=frames[start:]
            for f in fr:
                if f.get("type")=="system" and f.get("subtype")=="init":
                    print("  init.tools has SendUserFile:", "SendUserFile" in f["tools"], "| EndConversation:", "EndConversation" in f["tools"], "| tools:", len(f["tools"]), "| fast_mode_state:", f.get("fast_mode_state"), f.get("fast_mode_disabled_reason")); print("  TOOLS:", ",".join(f["tools"]))
                if f.get("type")=="result":
                    print(f"  user {val[:30]!r} → result: {str(f.get('result'))[:160]!r} | fast_mode_state={f.get('fast_mode_state')} reason={f.get('fast_mode_disabled_reason')}")
    ctl("end_session"); time.sleep(1)
    try: p.stdin.close()
    except: pass
    try: p.wait(timeout=15)
    except: p.kill()
    err=p.stderr.read()
    if err.strip(): print("  stderr:", err[-300:].strip())
run({"CLAUDE_CODE_ENTRYPOINT":"local-agent"}, [("user","Reply with the single word: ok")], "B: CLAUDE_CODE_ENTRYPOINT=local-agent → tools list")
