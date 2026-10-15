"""Authenticated loopback SOAP fixture; no real credentials or devices."""
import base64
import hashlib
import hmac
import io
import xml.etree.ElementTree as ET
from http.server import ThreadingHTTPServer
from fixture_server import HTTPFixture

class AuthenticatedFixture(HTTPFixture):
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'))
        if size>100000:self.send_error(413);return
        data=self.rfile.read(size)
        try:
            root=ET.fromstring(data)
            wsse='{http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd}'
            wsu='{http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd}'
            username=root.find('.//'+wsse+'Username').text
            nonce=base64.b64decode(root.find('.//'+wsse+'Nonce').text)
            created=root.find('.//'+wsu+'Created').text
            digest=root.find('.//'+wsse+'Password').text
            expected=base64.b64encode(hashlib.sha1(nonce+created.encode()+b'fixture-pass').digest()).decode()
            valid=username=='fixture-user' and hmac.compare_digest(digest,expected)
        except Exception:valid=False
        if not valid:
            self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="CamDesk fixture"');self.send_header('Content-Length','0');self.end_headers();return
        self.rfile=io.BytesIO(data)
        super().do_POST()

if __name__=='__main__':
    server=ThreadingHTTPServer(('127.0.0.1',19856),AuthenticatedFixture)
    print('Authenticated ONVIF fixture on 127.0.0.1:19856',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close()
