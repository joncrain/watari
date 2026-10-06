import Foundation
import Testing
import WatariCore

@Suite("HomePathMapper")
struct HomePathMapperTests {
    @Test("infers /Users home from offer paths")
    func inferHome() {
        let home = HomePathMapper.inferUserHome(from: [
            "/Users/joncrain/Desktop",
            "/Users/joncrain/Documents",
        ])
        #expect(home == "/Users/joncrain")
        #expect(HomePathMapper.userHomePrefix(of: "/Users/jon.crain/Desktop") == "/Users/jon.crain")
        #expect(HomePathMapper.userHomePrefix(of: "/Volumes/Data/Stuff") == nil)
    }

    @Test("maps Desktop between different home paths")
    func mapDesktop() {
        let destHome = URL(fileURLWithPath: "/Users/jon.crain", isDirectory: true)
        let mapped = HomePathMapper.mapRoot(
            sourceAbsolutePath: "/Users/joncrain/Desktop",
            sourceHome: "/Users/joncrain",
            destinationHome: destHome
        )
        #expect(mapped.path == "/Users/jon.crain/Desktop")
    }

    @Test("maps nested home-relative offers")
    func mapNested() {
        let destHome = URL(fileURLWithPath: "/Users/jon.crain", isDirectory: true)
        let offers = [
            OfferedRoot(name: "Foo", path: "/Users/joncrain/Projects/Foo", totalBytes: 1, entryCount: 1),
            OfferedRoot(name: "Desktop", path: "/Users/joncrain/Desktop", totalBytes: 2, entryCount: 2),
        ]
        let roots = HomePathMapper.destinationRoots(offers: offers, destinationHome: destHome)
        #expect(roots["Desktop"]?.path == "/Users/jon.crain/Desktop")
        #expect(roots["Foo"]?.path == "/Users/jon.crain/Projects/Foo")
    }

    @Test("override parent keeps legacy subfolder layout")
    func overrideParent() {
        let destHome = URL(fileURLWithPath: "/Users/jon.crain", isDirectory: true)
        let parent = URL(fileURLWithPath: "/Users/jon.crain/Transfers", isDirectory: true)
        let offers = [
            OfferedRoot(name: "Desktop", path: "/Users/joncrain/Desktop", totalBytes: 1, entryCount: 1),
        ]
        let roots = HomePathMapper.destinationRoots(
            offers: offers,
            destinationHome: destHome,
            overrideParent: parent
        )
        #expect(roots["Desktop"]?.path == "/Users/jon.crain/Transfers/Desktop")
    }
}
