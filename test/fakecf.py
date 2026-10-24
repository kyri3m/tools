import json, re, uuid, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
ZONES=[{'id':'z1','name':'example.com'}]
RECS={'z1':[{'id':'r0','type':'A','name':'old.example.com','content':'9.9.9.9','proxied':False,'ttl':1}]}
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): sys.stderr.write(self.command+' '+self.path+'\n')
    def reply(self,result,info=None):
        b=json.dumps({'success':True,'errors':[],'result':result,'result_info':info or {'total_pages':1}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b)
    def body(self):
        n=int(self.headers.get('Content-Length',0)); return json.loads(self.rfile.read(n)) if n else {}
    def handle_any(self):
        u=urlparse(self.path); q=parse_qs(u.query); p=u.path.replace('/client/v4','')
        if p=='/user/tokens/verify': return self.reply({'status':'active'})
        if p=='/zones': return self.reply(ZONES)
        m=re.fullmatch(r'/zones/(\w+)/dns_records(?:/(\w+))?',p)
        z,rid=m[1],m[2]; recs=RECS.setdefault(z,[])
        if self.command=='GET': return self.reply([r for r in recs if 'name' not in q or r['name']==q['name'][0]])
        if self.command=='POST':
            r=dict(self.body(),id=uuid.uuid4().hex[:8]); r.setdefault('proxied',False); recs.append(r); return self.reply(r)
        r=next(x for x in recs if x['id']==rid)
        if self.command=='PATCH': r.update(self.body()); return self.reply(r)
        if self.command=='DELETE': recs.remove(r); return self.reply({'id':rid})
    do_GET=do_POST=do_PATCH=do_DELETE=handle_any
HTTPServer(('127.0.0.1',18765),H).serve_forever()
