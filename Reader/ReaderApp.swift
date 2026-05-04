//
//  ReaderApp.swift
//  Reader
//
//  Created by Jim on 4/29/26.
//

import SwiftUI

@main
struct ReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 800, height: 600) // Initial window size
        .windowResizability(.contentSize) // Make window match content
    }
}
