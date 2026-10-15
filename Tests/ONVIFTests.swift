import Foundation

@main
struct ONVIFTests {
    static func parse(_ xml: String) throws -> ONVIFElement { try ONVIFParser.parse(Data(xml.utf8)) }
    static func main() async throws {
        // Independent SHA1 references: SHA1("abc") and a decoded-nonce WSSE vector.
        assert(ONVIFXML.passwordDigest(nonce: Data(), created: "", password: "abc") == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
        assert(ONVIFXML.passwordDigest(nonce: Data(base64Encoded: "WScqanjCEAC4mQoBE07sAQ==")!, created: "2003-07-16T01:24:32Z", password: "verySecret") == "wA/wIG0oKnlI6rjkbqV+JPygnPg=")
        let escaped = ONVIFXML.escape("<&>\"'")
        assert(escaped == "&lt;&amp;&gt;&quot;&apos;")
        let profileRoot = try parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:m="urn:media" xmlns:t="urn:schema"><s:Body><m:GetProfilesResponse><m:Profiles token="main&amp;one" fixed="true"><t:Name>Front &amp; Door</t:Name></m:Profiles><m:Profiles token="sub"><t:Name>Sub</t:Name></m:Profiles></m:GetProfilesResponse></s:Body></s:Envelope>
        """)
        let profiles = ONVIFXML.profiles(profileRoot)
        assert(profiles.count == 2 && profiles[0].0 == "main&one" && profiles[0].1 == "Front & Door")
        assert(profileRoot.first("Profiles")?.attributes["fixed"] == "true")
        let capabilities = try parse("<Capabilities><Media><XAddr>http://192.0.2.1/media</XAddr></Media><PTZ><XAddr>http://192.0.2.1/ptz</XAddr></PTZ></Capabilities>")
        assert(capabilities.first("Media")?.first("XAddr")?.value == "http://192.0.2.1/media")
        assert(capabilities.first("PTZ")?.first("XAddr")?.value == "http://192.0.2.1/ptz")
        let credentials = ONVIFCredentials(username: "fixture-user", password: "fixture-password")
        let basic = Data("fixture-user:fixture-password".utf8).base64EncodedString()
        let fault = try parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value></s:Code><s:Reason><s:Text>Denied fixture-user fixture-password \(basic)</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>
        """)
        let error = ONVIFXML.fault(fault, credentials: credentials, status: 500)!
        let message = error.localizedDescription
        assert(message.contains("HTTP 500") && message.contains("s:Sender"))
        assert(!message.contains(credentials.username) && !message.contains(credentials.password) && !message.contains(basic))
        let oldFault = try parse("<Envelope><Body><Fault><faultcode>Client</faultcode><faultstring>Bad token</faultstring></Fault></Body></Envelope>")
        assert(ONVIFXML.fault(oldFault, credentials: credentials)!.localizedDescription.contains("Bad token"))
        assert(ONVIFXML.fault(profileRoot, credentials: credentials) == nil)
        let security = ONVIFXML.security(credentials)
        assert(!security.contains(credentials.password))
        let securityRoot = try parse("<s:Header xmlns:s='http://www.w3.org/2003/05/soap-envelope'>\(security)</s:Header>")
        let nonce = Data(base64Encoded: securityRoot.first("Nonce")!.value)!
        assert(nonce.count == 20)
        assert(securityRoot.first("Password")!.value == ONVIFXML.passwordDigest(nonce: nonce, created: securityRoot.first("Created")!.value, password: credentials.password))
        let discovery = try parse("""
        <d:ProbeMatches xmlns:d="urn:discovery" xmlns:a="urn:address"><d:ProbeMatch><a:EndpointReference><a:Address>urn:uuid:fixture</a:Address></a:EndpointReference><d:Types>dn:NetworkVideoTransmitter</d:Types><d:Scopes>onvif://www.onvif.org/name/Front%20Door onvif://www.onvif.org/location/Lobby</d:Scopes><d:XAddrs>ftp://invalid http://192.0.2.1/onvif/device_service http://192.0.2.2/onvif</d:XAddrs></d:ProbeMatch></d:ProbeMatches>
        """)
        let devices = ONVIFXML.devices(discovery)
        assert(devices.count == 1 && devices[0].id == "urn:uuid:fixture" && devices[0].name == "Front Door")
        assert(devices[0].endpoint.host == "192.0.2.1" && devices[0].scopes.count == 2)
        assert(ONVIFXML.endpoint("http://user:password@192.0.2.1") == nil)
        assert(ONVIFXML.velocity(3) == 1 && ONVIFXML.velocity(-3) == -1)
        assert(ONVIFXML.velocity(.nan) == 0 && ONVIFXML.velocity(.infinity) == 0)
        do { _ = try parse("<broken>"); assertionFailure("Malformed XML accepted") } catch ONVIFError.malformedXML { }
        // Validation occurs before networking, ensuring missing credentials are never fake success.
        let client = ONVIFClient(endpoint: URL(string: "http://192.0.2.1/onvif")!, credentials: ONVIFCredentials(username: "", password: ""))
        do { _ = try await client.profiles(); assertionFailure("Missing credentials accepted") } catch ONVIFError.missingCredentials { }
        do { _ = try await ONVIFDiscovery().discover(timeout: 0); assertionFailure("Invalid timeout accepted") } catch ONVIFError.discovery { }
        print("ONVIFTests: all offline assertions passed")
    }
}
