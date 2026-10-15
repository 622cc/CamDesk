import Foundation

@main struct ModelTests {
    static func main() throws {
        let camera=CameraRecord(name:"Fixture",group:"Tests",hostHint:"127.0.0.1")
        let secret=ConnectionSecrets(streamURL:"rtsp://127.0.0.1/test",onvifEndpoint:"http://127.0.0.1/onvif/device_service",username:"fixture-user",password:"fixture-secret-value")
        let state=PersistedState(cameras:[camera],preferences:Preferences())
        let data=try JSONEncoder().encode(state)
        let text=String(decoding:data,as:UTF8.self)
        assert(!text.contains("fixture-secret-value") && !text.contains("rtsp://"))
        let decoded=try JSONDecoder().decode(PersistedState.self,from:data)
        assert(decoded.cameras.first?.id==camera.id && decoded.cameras.first?.group=="Tests")
        print("PASS config roundtrip preserves identity without connection secrets")
        let vault=CredentialVault();let testID=UUID()
        defer {try? vault.remove(testID)}
        try vault.save(secret,id:testID)
        let initial=try vault.load(testID)
        assert(initial?.password==secret.password)
        var changed=secret;changed.password="updated-fixture-value"
        try vault.save(changed,id:testID)
        let updated=try vault.load(testID)
        assert(updated?.password==changed.password)
        try vault.remove(testID)
        let deleted=try vault.load(testID)
        assert(deleted==nil)
        print("PASS actual Keychain add/read/update/remove using a unique test item")
        let exported=CameraArchive(cameras:[ArchiveCamera(camera:camera,streamURL:secret.streamURL,onvifEndpoint:secret.onvifEndpoint,username:secret.username)])
        let exportedData=try JSONEncoder().encode(exported)
        assert(!String(decoding:exportedData,as:UTF8.self).contains("fixture-secret-value"))
        let imported=try JSONDecoder().decode(CameraArchive.self,from:exportedData)
        assert(imported.cameras.count==1)
        print("PASS export schema roundtrip excludes password")
    }
}
