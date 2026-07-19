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
        // 백그라운드 태스크로 옮긴 이유: `setActive` 는 mediaserverd 로의
        // 동기 IPC 라 iOS 26+ 가 메인스레드 호출에 UI 정지 경고를 찍는다
        // (AVAudioSession_iOS.mm:978). 평소엔 수 ms 지만 mediaserverd 가
        // 바쁘면 런치 프레임을 먹을 수 있다 — HangWatchdog 까지 두고 메인
        // 정지를 잡는 앱이 런치에서 자초할 이유가 없다. 첫 영상 재생은
        // 사용자가 목록→상세로 이동한 뒤라(수 초 뒤) 완료 순서 race 없음.
        #if os(iOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
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
            // 2026 재디자인 셸(유리 탭바). 구 ContentView 드로어 셸은 Phase 5 에서 제거됨.
            RootTabView()
        }
    }
}
