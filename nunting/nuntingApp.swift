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

        // Register libwebp coder + cache budgets BEFORE the first
        // `AnimatedImage` view materialises. A late `addCoder` would let
        // the first round of WebP fetches go through ImageIO and stay
        // cached as ImageIO-decoded `.image` results — subsequent
        // animated WebP would still play but the first ones would
        // forever load slow on cache hits.
        SDWebImageSetup.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
