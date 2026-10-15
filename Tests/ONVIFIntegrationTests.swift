import Foundation

@main struct ONVIFIntegrationTests {
    static func main() async {
        do {
            let endpoint=URL(string:"http://127.0.0.1:19856/onvif/device_service")!
            let client=ONVIFClient(endpoint:endpoint,credentials:ONVIFCredentials(username:"fixture-user",password:"fixture-pass"))
            let profiles=try await client.profiles()
            guard profiles.count==1,profiles[0].id=="profile-main",profiles[0].streamURL?.host=="127.0.0.1" else {fatalError("Profiles/URI mismatch")}
            print("PASS WSSE authenticated capabilities + profiles + stream URI")
            try await client.move(profileToken:profiles[0].id,pan:0.5,tilt:-0.25,zoom:0)
            try await client.stop(profileToken:profiles[0].id)
            try await client.move(profileToken:profiles[0].id,pan:0,tilt:0,zoom:0.5)
            try await client.stop(profileToken:profiles[0].id)
            try await client.home(profileToken:profiles[0].id)
            let presets=try await client.presets(profileToken:profiles[0].id)
            guard let first=presets.first,first.name=="Front door" else {fatalError("Preset mismatch")}
            try await client.gotoPreset(profileToken:profiles[0].id,presetToken:first.id)
            print("PASS actual PTZ pan/tilt/zoom/stop/home/presets/goto HTTP requests")
            let bad=ONVIFClient(endpoint:endpoint,credentials:ONVIFCredentials(username:"fixture-user",password:"wrong-fixture-pass"))
            do {_ = try await bad.profiles();fatalError("Invalid credential accepted")}
            catch {guard case ONVIFError.http(401)=error else {throw error};print("PASS incorrect credentials produce HTTP 401")}
            let (data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:19856/health")!)
            let status=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let actions=status["actions"] as! [String]
            for action in ["GetCapabilities","GetProfiles","GetStreamUri","ContinuousMove","Stop","GotoHomePosition","GetPresets","GotoPreset"] {guard actions.contains(action) else {fatalError("Missing SOAP action")}}
            print("ALL ONVIF HTTP INTEGRATION TESTS PASSED")
        } catch {print("FAIL: \(error.localizedDescription)");exit(1)}
    }
}
