//
//  JianIOSApp.swift
//  Jian-iOS
//
//  Created by Gaofei on 2026/7/31.
//

import SwiftUI

@main
struct JianIOSApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
    }
}
