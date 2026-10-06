import Testing
import WatariCore

@Suite("Denylist")
struct DenylistTests {
    let deny = Denylist()

    @Test("blocks keychain paths")
    func keychains() {
        #expect(deny.blocks(relativePath: "Library/Keychains/login.keychain-db"))
        #expect(deny.blocks(relativePath: "Documents/../Library/Keychains/foo"))
        #expect(deny.blocks(relativePath: "secret.keychain-db"))
    }

    @Test("blocks TCC database")
    func tcc() {
        #expect(deny.blocks(relativePath: "Library/Application Support/com.apple.TCC/TCC.db"))
    }

    @Test("blocks configuration profiles")
    func profiles() {
        #expect(deny.blocks(relativePath: "Library/Managed Preferences/foo.plist"))
        #expect(deny.blocks(relativePath: "Library/ConfigurationProfiles/profile.mobileconfig"))
        #expect(deny.blocks(relativePath: "Downloads/corp.mobileconfig"))
    }

    @Test("allows ordinary documents")
    func allowsDocs() {
        #expect(!deny.blocks(relativePath: "Documents/Projects/readme.txt"))
        #expect(!deny.blocks(relativePath: "Desktop/photo.jpg"))
    }

    @Test("warns when selecting Library roots")
    func libraryWarning() {
        #expect(deny.warningForSelectingLibraryRoot("/Users/ada/Library") != nil)
        #expect(deny.warningForSelectingLibraryRoot("/Library") != nil)
        #expect(deny.warningForSelectingLibraryRoot("/Users/ada/Documents") == nil)
    }
}
