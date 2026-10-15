"""Local-only synthetic camera fixtures: ONVIF SOAP, HLS/MJPEG, RTSP TCP/UDP."""
import argparse
import base64
import json
import os
import re
import socket
import socketserver
import struct
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get('CAMDESK_FIXTURE_ROOT', Path(__file__).resolve().parent / 'artifacts' / 'network-fixtures'))
ACTIONS = []

class HTTPFixture(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == '/health':
            data = json.dumps({'fixture':True,'actions':ACTIONS}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        if self.path == '/mjpeg':
            self.send_response(200);self.send_header('Content-Type','multipart/x-mixed-replace; boundary=camdeskframe');self.end_headers()
            try:
                for _ in range(600):
                    image=(ROOT/'snapshot.jpg').read_bytes()
                    self.wfile.write(b'--camdeskframe\r\nContent-Type: image/jpeg\r\nContent-Length: '+str(len(image)).encode()+b'\r\n\r\n'+image+b'\r\n');self.wfile.flush();time.sleep(1/12)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        super().do_GET()
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'))
        if size > 100000:
            self.send_error(413);return
        text=self.rfile.read(size).decode('utf-8')
        known=['GetCapabilities','GetServices','GetProfiles','GetStreamUri','ContinuousMove','Stop','GotoHomePosition','GetPresets','GotoPreset']
        action=next((a for a in known if re.search(r'<(?:\w+:)?'+a+r'(?:\s|/|>)',text)), 'Unknown')
        ACTIONS.append(action)
        base=f'http://127.0.0.1:{self.server.server_port}'
        if action == 'GetCapabilities':
            body=f'<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media><tt:XAddr>{base}/onvif/media</tt:XAddr></tt:Media><tt:PTZ><tt:XAddr>{base}/onvif/ptz</tt:XAddr></tt:PTZ></tds:Capabilities></tds:GetCapabilitiesResponse>'
        elif action == 'GetServices':
            body=f'<tds:GetServicesResponse><tds:Service><tds:Namespace>http://www.onvif.org/ver10/media/wsdl</tds:Namespace><tds:XAddr>{base}/onvif/media</tds:XAddr></tds:Service><tds:Service><tds:Namespace>http://www.onvif.org/ver20/ptz/wsdl</tds:Namespace><tds:XAddr>{base}/onvif/ptz</tds:XAddr></tds:Service></tds:GetServicesResponse>'
        elif action == 'GetProfiles':
            body='<trt:GetProfilesResponse><trt:Profiles token="profile-main"><tt:Name>Fixture Main</tt:Name><tt:PTZConfiguration token="ptz-main"><tt:Name>Fixture PTZ</tt:Name></tt:PTZConfiguration></trt:Profiles></trt:GetProfilesResponse>'
        elif action == 'GetStreamUri':
            body='<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://127.0.0.1:19854/live</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>'
        elif action == 'GetPresets':
            body='<tptz:GetPresetsResponse><tptz:Preset token="preset-1"><tt:Name>Front door</tt:Name></tptz:Preset></tptz:GetPresetsResponse>'
        elif action in ['ContinuousMove','Stop','GotoHomePosition','GotoPreset']:
            body=f'<tptz:{action}Response/>'
        else:
            body='<s:Fault><s:Code><s:Value>s:Sender</s:Value></s:Code><s:Reason><s:Text xml:lang="en">Unsupported fixture action</s:Text></s:Reason></s:Fault>'
        data=('<?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>'+body+'</s:Body></s:Envelope>').encode()
        self.send_response(200);self.send_header('Content-Type','application/soap+xml; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)


def nals():
    raw=(ROOT/'fixture.h264').read_bytes()
    return [p for p in re.split(b'\x00\x00\x00?\x01',raw) if p]

class RTSPFixture(socketserver.StreamRequestHandler):
    def setup(self):
        super().setup();self.output_lock=threading.Lock();self.stopping=threading.Event();self.sender=None;self.udp=None;self.transport='tcp';self.channel=0;self.destination=None
    def respond(self, code, seq, headers=None, body=b''):
        h={'CSeq':seq,'Server':'CamDesk-Local-Test','Session':'12345678','Content-Length':str(len(body)),**(headers or {})}
        data=f'RTSP/1.0 {code}\r\n'.encode()+b''.join(f'{k}: {v}\r\n'.encode() for k,v in h.items())+b'\r\n'+body
        with self.output_lock:self.connection.sendall(data)
    def handle(self):
        try:
            while not self.stopping.is_set():
                first=self.rfile.read(1)
                if not first:break
                if first==b'$':
                    rest=self.rfile.read(3)
                    if len(rest)!=3:break
                    self.rfile.read(struct.unpack('!H',rest[1:])[0]);continue
                line=first+self.rfile.readline(8192)
                parts=line.decode(errors='replace').strip().split()
                if len(parts)!=3:break
                method,url,_=parts;headers={}
                while True:
                    line=self.rfile.readline(8192)
                    if line in [b'\r\n',b'\n',b'']:break
                    key,_,value=line.decode(errors='replace').partition(':');headers[key.lower()]=value.strip()
                if int(headers.get('content-length','0')):self.rfile.read(int(headers['content-length']))
                seq=headers.get('cseq','1')
                if method=='OPTIONS':self.respond('200 OK',seq,{'Public':'OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN'})
                elif method=='DESCRIBE':
                    units=nals();sps=next(n for n in units if n[0]&31==7);pps=next(n for n in units if n[0]&31==8)
                    description=('v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=CamDesk Synthetic Camera\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;sprop-parameter-sets='+base64.b64encode(sps).decode()+','+base64.b64encode(pps).decode()+'\r\na=control:trackID=0\r\n').encode()
                    self.respond('200 OK',seq,{'Content-Type':'application/sdp','Content-Base':url.rstrip('/')+'/'},description)
                elif method=='SETUP':
                    transport=headers.get('transport','')
                    if 'TCP' in transport.upper():
                        match=re.search(r'interleaved=(\d+)-(\d+)',transport);self.channel=int(match[1]) if match else 0;self.transport='tcp'
                        self.respond('200 OK',seq,{'Transport':f'RTP/AVP/TCP;unicast;interleaved={self.channel}-{self.channel+1}'})
                    else:
                        match=re.search(r'client_port=(\d+)-(\d+)',transport)
                        if not match:self.respond('461 Unsupported Transport',seq);continue
                        self.transport='udp';self.udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.udp.bind(('127.0.0.1',0));port=self.udp.getsockname()[1];self.destination=(self.client_address[0],int(match[1]))
                        self.respond('200 OK',seq,{'Transport':f'RTP/AVP;unicast;client_port={match[1]}-{match[2]};server_port={port}-{port+1}'})
                elif method=='PLAY':
                    self.respond('200 OK',seq,{'Range':'npt=0.000-','RTP-Info':url.rstrip('/')+'/trackID=0'})
                    if not self.sender:self.sender=threading.Thread(target=self.send_video,daemon=True);self.sender.start()
                elif method=='TEARDOWN':self.respond('200 OK',seq);break
                else:self.respond('200 OK',seq)
        except (OSError,ValueError):pass
        finally:
            self.stopping.set()
            if self.udp:self.udp.close()
    def send_video(self):
        units=nals();frames=[];frame=[]
        for unit in units:
            if unit[0]&31==9 and frame:frames.append(frame);frame=[]
            frame.append(unit)
        if frame:frames.append(frame)
        sequence=0;timestamp=0
        def packet(payload,marker):
            nonlocal sequence
            data=struct.pack('!BBHII',128,96|(128 if marker else 0),sequence%65536,timestamp%4294967296,0x43414d44)+payload;sequence+=1
            if self.transport=='udp':self.udp.sendto(data,self.destination)
            else:
                with self.output_lock:self.connection.sendall(b'$'+bytes([self.channel])+struct.pack('!H',len(data))+data)
        try:
            while not self.stopping.is_set():
                for frame in frames:
                    if self.stopping.is_set():return
                    send=[n for n in frame if n[0]&31 not in [9]]
                    for i,unit in enumerate(send):
                        last=i==len(send)-1
                        if len(unit)<=1200:packet(unit,last)
                        else:
                            chunks=[unit[j:j+1198] for j in range(1,len(unit),1198)]
                            for j,chunk in enumerate(chunks):
                                header=bytes([(unit[0]&0xe0)|28,(unit[0]&31)|(128 if j==0 else 0)|(64 if j==len(chunks)-1 else 0)])
                                packet(header+chunk,last and j==len(chunks)-1)
                    timestamp+=7500
                    self.stopping.wait(1/12)
        except OSError:self.stopping.set()

class RTSPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=19855);args=parser.parse_args()
    ROOT.mkdir(parents=True,exist_ok=True)
    rtsp=RTSPServer(('127.0.0.1',19854),RTSPFixture)
    threading.Thread(target=rtsp.serve_forever,daemon=True).start()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),HTTPFixture)
    print(f'Local fixture HTTP {args.port}, RTSP 19854',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close();rtsp.shutdown();rtsp.server_close()
