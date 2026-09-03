import json, subprocess, sys, uuid, time, threading, os
from collections import Counter
cwd=sys.argv[1]
def run(extra_flags, label, steps):
    cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--replay-user-messages","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]+extra_flags
    p=subprocess.Popen(cmd,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
    frames=[]; lock=threading.Lock()
    def send(o):
        try: p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
        except Exception as e: print("  send failed:", e)
    def reader():
        for line in p.stdout:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except: continue
            with lock: frames.append(m)
    threading.Thread(target=reader,daemon=True).start()
    def ctl(sub,**kw):
        r=str(uuid.uuid4()); send({"type":"control_request","request_id":r,"request":{"subtype":sub,**kw}}); return r
    def wait_ctl(r,timeout=20):
        t=time.time()
        while time.time()-t<timeout:
            with lock:
                for f in frames:
                    if f.get("type")=="control_response" and (f.get("response") or {}).get("request_id")==r: return f["response"]
            if p.poll() is not None: return None
            time.sleep(0.2)
    print(f"===== {label}: {' '.join(extra_flags)}")
    r=wait_ctl(ctl("initialize",supportedDialogKinds=[]))
    if r is None:
        print("  process exited early, code", p.poll(), "stderr:", p.stderr.read()[-400:].strip()); return
    time.sleep(2)
    for kind,val in steps:
        if kind=="ctl":
            sub,kw=val; rr=wait_ctl(ctl(sub,**kw)); print(f"  ctl {sub} {json.dumps(kw)} → {json.dumps((rr or {}).get('response') if (rr or {}).get('subtype')=='success' else (rr or {}).get('error'))[:300]}")
        else:
            start=len(frames)
            send({"type":"user","uuid":str(uuid.uuid4()),"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":val}})
            t=time.time()
            while time.time()-t<60:
                with lock: fr=frames[start:]
                if any(f.get("type")=="result" for f in fr): break
                time.sleep(0.2)
            with lock: fr=frames[start:]
            from collections import Counter
            print(f"  user {val!r} → census:", Counter((f.get('type'),f.get('subtype') or '') for f in fr).most_common())
            for f in fr:
                if f.get("type")=="transcript_mirror": print("   transcript_mirror:", json.dumps(f)[:400])
    with lock: kinds=Counter((f.get('type'),f.get('subtype') or '') for f in frames)
    print("  ALL FRAME KINDS:", kinds.most_common())
    ctl("end_session"); time.sleep(1)
    try: p.stdin.close()
    except: pass
    try: p.wait(timeout=15)
    except: p.kill()
    err=p.stderr.read().strip()
    if err: print("  stderr tail:", err[-300:])
run(["--enable-auth-status"], "B enable-auth-status", [("ctl",("get_binary_version",{})),("user","/goal")])
