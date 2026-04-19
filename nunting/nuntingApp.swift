//
//  nuntingApp.swift
//  nunting
//
//  Created by youngmin Moon on 4/17/26.
//

import SwiftUI
import AVFoundation

@main
struct nuntingApp: App {
    init() {
        // Configure audio session for inline video playback. Without this,
        // unmuting an autoplay video has no effect (default category mutes
        // app audio on the iPhone silent switch and prevents AVPlayer from
        // outputting sound). `.playback` lets the user toggle volume via the
        // system video controls and actually hear it, without needing to
        // reload the player. AVAudioSession is iOS-only.
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
