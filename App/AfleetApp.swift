import SwiftUI

// The app links all four packages. Task 3's composition root is what will use FleetKit's
// `Fleet` and `TranscriptIndex`; the import is here today so the shell's dependency on the
// package is expressed in source and not only in the manifest.
import FleetKit

/// The application entry point. Today the scene exists so the target links, launches and
/// shows a window titled `afleet`; Task 3 replaces its content with the router.
@main
struct AfleetApp: App {
    var body: some Scene {
        WindowGroup("afleet") {
            RootPlaceholderView()
        }
    }
}
