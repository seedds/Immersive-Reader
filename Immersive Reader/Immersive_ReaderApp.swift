//
//  Immersive_ReaderApp.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import SwiftUI
import SwiftData

@main
struct Immersive_ReaderApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Book.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
