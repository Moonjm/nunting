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
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Configure audio session for inline video playback. Without this,
        // unmuting an autoplay video has no effect (default category mutes
        // app audio on the iPhone silent switch and prevents AVPlayer from
        // outputting sound). `.playback` lets the user toggle volume via the
        // system video controls and actually hear it, without needing to
        // reload the player. AVAudioSession is iOS-only.
        //
        // `.mixWithOthers`: without it, activating a `.playback` session is
        // exclusive and interrupts any audio already playing from another
        // app (Spotify, Apple Music, podcasts). Since the inline body videos
        // are all muted autoplay, they have no reason to silence the user's
        // background music just by scrolling into view — mixing keeps that
        // music going. A fullscreen video the user explicitly opened still
        // outputs sound (it just plays over the music rather than killing it).
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
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
            // 2026 재디자인 셸. 구버전(ContentView)은 검증 전까지 보존.
            RootTabView()
        }
    }
}
