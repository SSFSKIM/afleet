import json, subprocess, sys, uuid, time, threading, os
from collections import Counter
cwd=sys.argv[1]
def run(extra_env,label):
    env=dict(os.environ); env.update(extra_env)
    cmd=["claude","-p","--input-format","stream-json","--output-format","stream-json","--replay-user-messages","--include-partial-messages","--permission-prompt-tool","stdio","--permission-prompts","host","--permission-mode","default","--model","haiku","--verbose"]
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
    send({"type":"control_request","request_id":str(uuid.uuid4()),"request":{"subtype":"initialize","supportedDialogKinds":[]}})
    time.sleep(3)
    send({"type":"user","uuid":str(uuid.uuid4()),"parent_tool_use_id":None,"origin":{"kind":"human"},"message":{"role":"user","content":"Use the Bash tool (foreground, not background) to run exactly: for i in 1 2 3 4 5; do echo line-$i; sleep 1; done . Then reply with the single word: done"}})
    t=time.time()
    while time.time()-t<120:
        with lock: done=any(f.get("type")=="result" for f in frames)
        if done: break
        time.sleep(0.2)
    print(f"===== {label}")
    with lock:
        print("  census:", Counter((f.get('type'),f.get('subtype') or '') for f in frames if f.get('type')!='stream_event').most_common())
        for f in frames:
            if f.get("type")=="tool_progress": print("  tool_progress:", json.dumps({k:v for k,v in f.items() if k not in ('session_id','uuid')})[:300])
            if f.get("type")=="system" and f.get("subtype")=="init": print("  init keys extra:", {k:f.get(k) for k in ('worker_epoch','fast_mode_state','effort')})
    send({"type":"control_request","request_id":str(uuid.uuid4()),"request":{"subtype":"end_session"}}); time.sleep(1)
    try: p.stdin.close()
    except: pass
    try: p.wait(timeout=15)
    except: p.kill()
run({"CLAUDE_CODE_CONTAINER_ID":"afleet-probe"}, "CLAUDE_CODE_CONTAINER_ID set: does tool_progress carry output?")
