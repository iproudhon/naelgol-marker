import Foundation

/// Lays one hole out in screen space: **tee at the bottom, green at the top**,
/// rotated to the tee→green bearing.
///
/// Pure arithmetic on purpose — no CoreGraphics, no SwiftUI — so the handedness
/// can be tested without a renderer. A mirrored projection still puts the green
/// above the tee and still looks like a golf hole, so "green is up" proves
/// nothing; the assertion that catches it is that a point **right** of the
/// tee→green line (`Geodesy.side` negative) must land at a **larger x**.
public struct HolePlane: Sendable {
    /// Along-hole and across-hole metres, before scaling.
    public struct Local: Sendable { public var forward: Double; public var right: Double }

    public let origin: Coordinate
    public let headingRadians: Double
    public let scale: Double          // points per metre, *including* `view.zoom`
    private let minForward: Double, minRight: Double
    private let offsetX: Double, offsetY: Double
    private let height: Double
    /// The fitted layout, before `view.zoom` — kept so a zoom can be re-solved
    /// **about a screen point** rather than about the layout's centre. See
    /// `zooming(to:about:)`; without these the arithmetic is not invertible from
    /// a finished plane and the pinch has to guess.
    private let baseScale: Double
    private let spanForward: Double, spanRight: Double
    private let baseX: Double, baseY: Double
    /// The user's pan and zoom, already folded into `scale`, `offsetX` and
    /// `offsetY`. Kept for `View.clamped` and for debugging, not re-applied.
    public let view: View

    /// What the golfer's fingers did to the framing.
    ///
    /// **This lives in the plane and never in a SwiftUI modifier.** A
    /// `.scaleEffect`/`.offset` on the `Canvas` would move the pixels while
    /// `project` and `unproject` kept describing the *unzoomed* layout — so every
    /// tap would land somewhere other than the finger, and it would look perfectly
    /// correct until someone tried to place a target while zoomed in. Folding the
    /// transform in here keeps projection and its inverse a matched pair by
    /// construction.
    public struct View: Sendable, Equatable {
        /// Multiplier on the fitted scale. 1 is "the whole hole fits".
        public var zoom: Double
        /// Pan in **points, in screen orientation** — `panY` positive moves the
        /// hole *down* the screen, the way `y` grows. Stated because the drag
        /// gesture originally negated it and the vector layer scrolled the opposite
        /// way to the finger; the convention has to live with the type, not in
        /// whichever gesture happens to set it.
        public var panX: Double, panY: Double

        public static let fitted = View(zoom: 1, panX: 0, panY: 0)

        public init(zoom: Double = 1, panX: Double = 0, panY: Double = 0) {
            self.zoom = zoom; self.panX = panX; self.panY = panY
        }

        /// **Up to 40×** *(user, 2026-08-28: "with my iphone, side span is about
        /// 45 yards, I want it to be around 10 yards, so that I can place putts
        /// better")*. The old ceiling of 8 fitted a hole and a bit of rough; a putt
        /// is read at a scale where the green fills the screen. Nothing downstream
        /// cares — `project`/`unproject` fold the zoom into `scale`, so the round
        /// trip a target relies on holds at any factor.
        public static let zoomRange: ClosedRange<Double> = 0.6...40

        /// **Zoom is clamped; pan is not.**
        ///
        /// Pan used to be held to half a screen so the hole could not be flung away
        /// and lost. That also made "go to my location" impossible the moment the
        /// golfer was not standing on the hole they were looking at — which is most
        /// of the time, and exactly when they want to see where they are relative to
        /// it. The recovery is *Fit hole to screen* in the pin menu rather than a
        /// limit that quietly refuses to go where it was asked.
        public func clamped(size: (width: Double, height: Double)) -> View {
            View(zoom: min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
                 panX: panX, panY: panY)
        }
    }

    /// Space the hole must keep clear of, per edge. Not decoration: the HUD sits
    /// over the top and bottom of this screen, and a hole fitted to the raw view
    /// puts its tee box underneath the controls where nobody can see it.
    public struct Insets: Sendable {
        public var top: Double, bottom: Double, leading: Double, trailing: Double
        public init(top: Double = 24, bottom: Double = 24,
                    leading: Double = 24, trailing: Double = 24) {
            self.top = top; self.bottom = bottom
            self.leading = leading; self.trailing = trailing
        }
        public static func uniform(_ v: Double) -> Insets {
            Insets(top: v, bottom: v, leading: v, trailing: v)
        }
    }

    /// - Parameter fitting: every coordinate that must be visible. The tee and the
    ///   green are not assumed — pass hazards, tracks and the player too, or they
    ///   render off-screen.
    public init(origin: Coordinate, heading: Double,
                fitting points: [Coordinate],
                size: (width: Double, height: Double),
                insets: Insets = .uniform(24),
                viewport: View = .fitted) {
        self.origin = origin
        self.headingRadians = heading * .pi / 180
        let θ = self.headingRadians

        func local(_ c: Coordinate) -> Local {
            let o = Geodesy.offset(of: c, from: origin)
            return Local(forward: o.north * cos(θ) + o.east * sin(θ),
                         right: o.east * cos(θ) - o.north * sin(θ))
        }

        let ls = points.isEmpty ? [Local(forward: 0, right: 0)] : points.map(local)
        let minF = ls.map(\.forward).min()!, maxF = ls.map(\.forward).max()!
        let minR = ls.map(\.right).min()!, maxR = ls.map(\.right).max()!
        let spanF = max(1, maxF - minF), spanR = max(1, maxR - minR)

        let usableW = max(1, size.width - insets.leading - insets.trailing)
        let usableH = max(1, size.height - insets.top - insets.bottom)
        let s = min(usableW / spanR, usableH / spanF)

        // Zoom about the centre of the fitted layout, so pinching does not walk
        // the hole toward a corner.
        let v = viewport.clamped(size: size)
        let zs = s * v.zoom
        self.view = v
        self.scale = zs
        self.minForward = minF
        self.minRight = minR
        let baseX = insets.leading + (usableW - spanR * s) / 2
        let baseY = insets.bottom + (usableH - spanF * s) / 2
        self.offsetX = baseX - (spanR * (zs - s)) / 2 + v.panX
        self.offsetY = baseY - (spanF * (zs - s)) / 2 - v.panY
        self.height = size.height
        self.baseScale = s
        self.spanForward = spanF
        self.spanRight = spanR
        self.baseX = baseX
        self.baseY = baseY
    }

    /// A viewport at `zoom` that keeps whatever ground is under `point` **under
    /// `point`**.
    ///
    /// A pinch that zooms about the middle of the fitted layout throws the thing
    /// being looked at off the screen: at 40× a green under the fingers ends up
    /// several screens away, and the golfer reads that as the zoom not working
    /// rather than as the hole having moved. The pan is solved for instead, so the
    /// fingers stay on the ground they started on — which is what makes a putting
    /// zoom usable at all.
    ///
    /// Analytic rather than a search: the projection is affine in `zoom`, so the
    /// pan that pins one point is one line of algebra. The clamp is the same one
    /// `View.clamped` applies, so a pinch past the ceiling pins the point and stops
    /// scaling instead of drifting.
    public func zooming(to zoom: Double, about point: (x: Double, y: Double)) -> View {
        let z = min(max(zoom, View.zoomRange.lowerBound), View.zoomRange.upperBound)
        let right = (point.x - offsetX) / scale + minRight
        let forward = ((height - point.y) - offsetY) / scale + minForward
        let s = baseScale
        return View(zoom: z,
                    panX: point.x - (right - minRight) * s * z - baseX
                        + spanRight * s * (z - 1) / 2,
                    panY: point.y - height + (forward - minForward) * s * z + baseY
                        - spanForward * s * (z - 1) / 2)
    }

    public func local(_ c: Coordinate) -> Local {
        let o = Geodesy.offset(of: c, from: origin)
        let θ = headingRadians
        return Local(forward: o.north * cos(θ) + o.east * sin(θ),
                     right: o.east * cos(θ) - o.north * sin(θ))
    }

    /// Screen point. `y` grows downward, as every canvas does — the flip lives
    /// here and nowhere else.
    public func project(_ c: Coordinate) -> (x: Double, y: Double) {
        let l = local(c)
        return (x: (l.right - minRight) * scale + offsetX,
                y: height - ((l.forward - minForward) * scale + offsetY))
    }

    /// Screen point → coordinate. The exact inverse of `project`.
    ///
    /// Every touch interaction needs this — placing a target, dragging the
    /// simulated player — and it must stay the inverse of `project` **under the
    /// same `view`**, which is why the transform is a property of the plane rather
    /// than something the view layer does on its own.
    ///
    /// Returns a coordinate with no altitude: a tap is a position on the ground
    /// plane, and inventing an elevation for it would feed a plays-like number
    /// that nothing measured.
    public func unproject(x: Double, y: Double) -> Coordinate {
        let right = (x - offsetX) / scale + minRight
        let forward = ((height - y) - offsetY) / scale + minForward
        let θ = headingRadians
        // Inverse of `local`: rotate the along/across pair back onto east/north.
        let north = forward * cos(θ) - right * sin(θ)
        let east = forward * sin(θ) + right * cos(θ)
        // Built directly rather than through `Geodesy.coordinate`, which defaults a
        // nil altitude to the *origin's* — here that would silently stamp the tee's
        // elevation onto a point somewhere up the fairway and feed a plays-like
        // number that nothing measured.
        let p = Geodesy.coordinate(from: origin, east: east, north: north, alt: nil)
        return Coordinate(lat: p.lat, lon: p.lon, alt: nil)
    }

    /// Convenience for a whole hole: fits tee, line, green outline, hazards and
    /// anything extra (player position, shot tracks) into `size`.
    ///
    /// Takes `HoleGeometry`, not `Hole`, on purpose. This initialiser is pure
    /// arithmetic with no guard, so a card-only hole nil-coalesced to (0, 0)
    /// would render silently at the equator instead of failing — the resolved
    /// type makes that unrepresentable.
    public init(geometry g: HoleGeometry, extra: [Coordinate] = [],
                size: (width: Double, height: Double), insets: Insets = .uniform(24),
                viewport: View = .fitted) {
        self.init(origin: g.teeAt, heading: g.bearing,
                  fitting: g.allPoints + extra, size: size, insets: insets, viewport: viewport)
    }
}
