import subprocess, json, os, time, sys, uuid
args=["claude","-p","--input-format","stream-json","--output-format","stream-json","--verbose",
      "--include-partial-messages","--replay-user-messages","--forward-subagent-text",
      "--include-hook-events","--permission-prompt-tool","stdio","--permission-prompts","host"]
p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,cwd="/tmp")
rid=str(uuid.uuid4())
p.stdin.write(json.dumps({"type":"control_request","request_id":rid,"request":{"subtype":"initialize"}})+"\n"); p.stdin.flush()
got=None
t0=time.time()
while time.time()-t0<60:
    line=p.stdout.readline()
    if not line: break
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="control_response" and o.get("response",{}).get("request_id")==rid:
        got=o; break
print("PID", p.pid)
kids=subprocess.run(["pgrep","-P",str(p.pid)],capture_output=True,text=True).stdout.split()
print("children", kids)
d=os.path.expanduser("~/.claude/sessions")
before=set(os.listdir(d))
cands=[str(p.pid)]+kids
for c in cands:
    f=os.path.join(d,c+".json")
    print(c, "registry:", os.path.exists(f))
    if os.path.exists(f):
        print(json.dumps(json.load(open(f)),indent=1))
p.kill()
