import subprocess, json, os, time, uuid, threading
args=["claude","-p","--input-format","stream-json","--output-format","stream-json","--verbose",
      "--replay-user-messages","--permission-mode","plan","--model","claude-haiku-4-5-20251001"]
p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1,cwd="/tmp")
f=os.path.expanduser(f"~/.claude/sessions/{p.pid}.json")
samples=[]
stop=False
def poll():
    while not stop:
        try:
            d=json.load(open(f))
            samples.append((round(time.time()%1000,2), d.get("status"), d.get("tempo"), d.get("waitingFor"), d.get("state"), d.get("detail")))
        except Exception: pass
        time.sleep(0.25)
t=threading.Thread(target=poll,daemon=True); t.start()
p.stdin.write(json.dumps({"type":"user","message":{"role":"user","content":"Reply with the single word: ok"},"parent_tool_use_id":None,"uuid":str(uuid.uuid4())})+"\n"); p.stdin.flush()
t0=time.time()
while time.time()-t0<120:
    line=p.stdout.readline()
    if not line: break
    o=json.loads(line)
    if o.get("type")=="result": print("RESULT", o.get("subtype")); break
stop=True; time.sleep(0.4)
uniq=[]
for s in samples:
    if not uniq or uniq[-1][1:]!=s[1:]: uniq.append(s)
print("distinct registry states seen:")
for u in uniq: print("  ",u)
try:
    print("final:", json.dumps(json.load(open(f))))
except Exception as e: print("final read failed",e)
p.kill()
