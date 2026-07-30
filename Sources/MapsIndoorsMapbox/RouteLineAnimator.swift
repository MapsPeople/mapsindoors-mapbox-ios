//
//  RouteLineAnimator.swift
//  MapsIndoorsSDK
//
//  Created by Aditya Singh on 13/07/2026.
//  Copyright © 2026 MapsPeople A/S. All rights reserved.
//

import Foundation
import QuartzCore

/// A small, per-instance, main-thread route-line animator backed by `CADisplayLink`.
///
/// It replaces the vendored `ValueAnimator` for the route flow / pulse / comet animations: it drives a
/// normalized progress `0...1` over `duration`, optionally after a `startDelay` and repeating, delivering
/// `onProgress` (and, on natural completion, `onEnd`) on the **main thread**.
///
/// Unlike `ValueAnimator` it holds no static registry and runs no background thread — one display link per
/// instance on the main run loop — so it carries none of that type's cross-thread shared-state races.
///
/// - Important: All lifecycle methods (`start()` / `invalidate()`) must be called on the main thread, since a
///   `CADisplayLink` is bound to the run loop it is added to. This is asserted at runtime (debug) rather than
///   only documented. The check is `Thread.isMainThread` (not `dispatchPrecondition(.onQueue(.main))`) because
///   the contract is the main *thread* the link's run loop lives on, and `invalidate()` is also reached from the
///   `CADisplayLink` callback (`step`) — a run-loop context where `.onQueue(.main)` can spuriously fail.
final class RouteLineAnimator {

    /// How the `0...1` progress repeats once it reaches the end of a cycle.
    enum RepeatMode {
        /// Run once, then finish (fires `onEnd`).
        case once
        /// Run `n` cycles, then finish.
        case count(Int)
        /// Loop forever; never finishes.
        case infinite
    }

    /// Progress shaping. Only linear is needed today (the vendored animator was driven with a linear ease and
    /// the pulse curve lives in `RouteFlowGeometry`); the enum is the extension point if a curve is wanted.
    enum Easing {
        case linear
        func apply(_ t: Double) -> Double {
            switch self {
            case .linear: return t
            }
        }
    }

    /// Pure timeline math — maps elapsed seconds to `(progress, finished)` with no timer or wall clock, so it
    /// is unit-testable without a real `CADisplayLink`.
    struct Timeline {
        let duration: TimeInterval
        let startDelay: TimeInterval
        let repeatMode: RepeatMode
        let easing: Easing

        struct Sample {
            let progress: Double
            let finished: Bool
        }

        func sample(elapsed: TimeInterval) -> Sample {
            let active = elapsed - startDelay
            if active <= 0 { return Sample(progress: easing.apply(0), finished: false) }   // still in the start delay
            if duration <= 0 { return Sample(progress: easing.apply(1), finished: true) }  // degenerate: finish at once
            let cycles = active / duration
            switch repeatMode {
            case .once:
                return cycles >= 1
                    ? Sample(progress: easing.apply(1), finished: true)
                    : Sample(progress: easing.apply(cycles), finished: false)
            case .count(let n):
                let maxCycles = Double(max(n, 1))
                return cycles >= maxCycles
                    ? Sample(progress: easing.apply(1), finished: true)
                    : Sample(progress: easing.apply(cycles - cycles.rounded(.down)), finished: false)
            case .infinite:
                return Sample(progress: easing.apply(cycles - cycles.rounded(.down)), finished: false)
            }
        }
    }

    /// `CADisplayLink` strongly retains its target, so target it at a weak proxy — otherwise the link would
    /// keep the animator (and everything it captures) alive and ticking forever.
    private final class Proxy {
        weak var animator: RouteLineAnimator?
        init(_ animator: RouteLineAnimator) { self.animator = animator }
        @objc func step(_ link: CADisplayLink) { animator?.step(link) }
    }

    private let timeline: Timeline
    private let onProgress: (Double) -> Void
    private let onEnd: (() -> Void)?

    private var displayLink: CADisplayLink?
    private var startTimestamp: CFTimeInterval?

    /// Whether the animator is currently ticking. Read by the renderers to skip a draw once it has stopped.
    private(set) var isRunning = false

    init(duration: TimeInterval,
         repeatMode: RepeatMode = .once,
         startDelay: TimeInterval = 0,
         easing: Easing = .linear,
         onProgress: @escaping (Double) -> Void,
         onEnd: (() -> Void)? = nil) {
        self.timeline = Timeline(duration: duration, startDelay: startDelay, repeatMode: repeatMode, easing: easing)
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    deinit {
        // A CADisplayLink must be invalidated on the run loop it was added to (main). In normal use it's already
        // invalidated on main before dealloc; this is the safety net if the last reference is released off-main
        // (e.g. during teardown) — dispatch the invalidate to main so it is always safe. Capturing only `link`
        // (never `self`, which is deallocating) avoids resurrection.
        let link = displayLink
        if Thread.isMainThread {
            link?.invalidate()
        } else {
            DispatchQueue.main.async { link?.invalidate() }
        }
    }

    /// Starts (or restarts) the animation from `0`. Main thread only.
    func start() {
        assert(Thread.isMainThread, "RouteLineAnimator.start() must be called on the main thread")
        invalidate()
        isRunning = true
        startTimestamp = nil
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.step(_:)))
        link.add(to: .main, forMode: .common)   // .common so the flow survives scroll / gesture tracking
        displayLink = link
    }

    /// Stops ticking without firing `onEnd`. Idempotent. Main thread only.
    func invalidate() {
        assert(Thread.isMainThread, "RouteLineAnimator.invalidate() must be called on the main thread")
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        startTimestamp = nil
    }

    private func step(_ link: CADisplayLink) {
        let start: CFTimeInterval
        if let existing = startTimestamp {
            start = existing
        } else {
            start = link.timestamp
            startTimestamp = start
        }
        let sample = timeline.sample(elapsed: link.timestamp - start)
        onProgress(sample.progress)
        if sample.finished {
            invalidate()
            onEnd?()
        }
    }
}
