import SwiftUI
import Combine

extension Notification.Name {
    /// Which cats live on the strip was changed in Settings (the strips pick the new set up).
    static let catRosterChanged = Notification.Name("freeflowCatRosterChanged")
}

/// How big the cats are drawn: a preference (Settings, on the Mac and on the iPhone). The strip is played in points that are a part of
/// the real ones and drawn scaled up from its top left corner (`CatRunner(scale:)`), so the cats, the toys and the hearts all grow or
/// shrink together and nothing about how they play changes.
enum CatSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// On the Mac's strip above the window. 1 is the size the cats have always had.
    var scale: CGFloat {
        switch self {
        case .small: return 0.75
        case .medium: return 1
        case .large: return 1.4
        }
    }

    /// On the iPhone, on top of the third that the shelf already draws its strip bigger by.
    var phoneScale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1
        case .large: return 1.2
        }
    }

    /// A size from what was saved (its raw name). Anything else, or nothing, is the usual size.
    static func from(_ saved: String?) -> CatSize { saved.flatMap { CatSize(rawValue: $0) } ?? .medium }
}

/// The cats that live on a strip (10 Nov 2026): on the Mac along the top edge of the window (CatPerch.swift), above the whole app; on
/// the iPhone, and inside a window with no room above it, along the top bar. There are six cats to choose from (up to three live on the
/// strip at a time, `roster`; Settings has the chooser). One is out and about: it walks
/// with a real eight-frame walk cycle (the ones Rhythme made), sits down to look at you, lies down for a lazy while, and when it is
/// tired it curls up and sleeps. The other two lie where they lie, breathing slowly, and when the sleeper has had enough one of them
/// gets up and takes over. Tap a cat that is lying down and it gets up and the one that was out lies down in its place.
///
/// The toys and the food are not lying about on the strip: they are in a tiny toy box inside the app (`CatToyBox`). Click one and it
/// bounces out of the app up onto the strip; click it again (or double-click it on the strip) and it goes back in the box.
/// You can play with the active cat. The ball: pick it up, move it about, let go, and it flies; the cat runs after it, jumps, catches
/// it, bats it away and goes again for a while. The wand (a stick with a ribbon, at the left end): pick it up and the ribbon swings
/// from the tip; the cat chases it, leaps for it and swats it. The fish biscuit: it drops onto the strip, the cat comes and eats it;
/// some time later it leaves a little pile, and a tap on the pile cleans it up. Left alone the cat plays with the ball (if it is out)
/// and has bursts of zoomies on its own. A tap on the cat makes it jump and send a heart.
/// The pictures are the same cats as the rest of the theme (Dreamy: lilac collars; Sunset: coral), so a colour change changes the
/// cats and the toys too. Nothing is drawn when Reduce motion is on.
///
/// Shared by the Mac app and the iPhone app: each supplies a `CatRunnerSkin` (where its pictures and colours come from). All the
/// behaviour is in `CatRunnerState`, plain arithmetic on the clock and on the finger, so it is checked without a window
/// (main.swift --test). Positions are in points from the left of the strip; heights (`by`, `Treat.y`, the lure) are above the line
/// the cat's paws stand on.
final class CatRunnerState: ObservableObject {
    enum Mode { case running, sitting, sleeping, lounging, chasing, pouncing, eating }
    enum Goal { case ball, treat, wand }
    enum Held { case none, ball, treat, wand }
    /// What is in the toy box. The ball and the wand come out and go back; the biscuit is eaten.
    enum Toy { case ball, wand, biscuit }

    struct Treat {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var held = true
        var settledAt: TimeInterval? = nil      // when it came to rest on the floor
        var eatStart: TimeInterval? = nil       // when the cat started on it
    }
    struct Poop { var x: CGFloat; var born: TimeInterval }

    /// The one strip the whole app shares (the toy box and the strip it throws things onto are two views of this).
    static let shared = CatRunnerState()
    static let names = ["cream", "ginger", "black", "smoky", "snowy", "cocoa"]
    static let titles = ["Mochi", "Mango", "Pepper", "Smoky", "Snowy", "Cocoa"]
    static let defaultRoster = ["cream", "ginger", "black"]
    static let rosterMax = 3                // cats on the strip at a time
    static let frames = 8                   // pictures in one stride of the walk strip
    static let stride: CGFloat = 34         // points the cat moves in one full stride (eight frames), about one body length
    static let speed: CGFloat = 40          // a stroll: points a second, so about 1.2 strides a second and the paws do not slide
    static let chaseSpeed: CGFloat = 96
    static let zoomSpeed: CGFloat = 104
    static let ballR: CGFloat = 12
    static let treatRest: CGFloat = 6       // height of a biscuit's middle when it lies on the floor
    static let gravity: CGFloat = 1100
    static let reach: CGFloat = 16          // how far from the ball (sideways) the cat can touch it
    static let reachUp: CGFloat = 34        // how high the bottom of the ball can be for the cat to get it (it jumps for the high ones)
    static let wandZone: CGFloat = 36       // the left end of the strip belongs to the wand (when it is out),
    static let rightMargin: CGFloat = 12    // and the right end is left clear
    static let stringLength: CGFloat = 30   // the ribbon on the wand
    static let playTime: TimeInterval = 14  // how long the cat keeps playing after you let go of the ball

    // the strip
    private(set) var width: CGFloat = 300
    private(set) var height: CGFloat = 80
    private(set) var floorInset: CGFloat = 4
    /// How much bigger than the strip's own points the view draws it (1 when the host draws it as it is). The strip is played in its own
    /// points, so whoever turns a pointer or a position on screen into one of them (the toy box, the Mac's click-through window) divides by this.
    private(set) var scale: CGFloat = 1

    // the cat that is out
    var x: CGFloat = 80                     // the middle of the cat
    var dir: CGFloat = 1                    // 1 to the right, -1 to the left
    var mode: Mode = .running
    var goal: Goal = .ball
    var until: TimeInterval = 0             // the mode ends here (seconds on the clock the caller passes in)
    var phase: Double = 0                   // strides walked so far (the fraction is where the cat is in its stride)
    var who = 0                             // which cat (an index into `names`)
    /// The cats on the strip, as indexes into `names`: `who` and the ones lying down.
    private(set) var roster: [Int] = [0, 1, 2]
    var last: TimeInterval = 0
    var jumpedAt: TimeInterval = -10
    var jumpAmp: CGFloat = 13
    var hearts: [(x: CGFloat, t: TimeInterval)] = []
    var prints: [(x: CGFloat, t: TimeInterval, up: Bool)] = []
    var sparkles: [(x: CGFloat, y: CGFloat, t: TimeInterval)] = []
    /// The cats that are not out lie where they are: cat number -> where (the middle of the cat).
    var lounge: [Int: CGFloat] = [:]
    private var step2 = 0
    private var rng = SystemRandomNumberGenerator()
    private var zoomUntil: TimeInterval = 0
    private var nextMischief: TimeInterval = 0
    private var pounceEnd: TimeInterval = 0
    private var carrying = false
    private var noPounceUntil: TimeInterval = 0
    private var eatAt: TimeInterval = 0
    private var poopDue: TimeInterval?
    private var lastPurr: TimeInterval = 0

    // the toy box: what is out on the strip
    @Published private(set) var ballOut = false
    @Published private(set) var wandOut = false
    var ballChanged: TimeInterval = -10     // when the ball last came out or went back (for the pop)
    var wandChanged: TimeInterval = -10
    private var lastTap: [Toy: TimeInterval] = [:]
    private var holdStart: TimeInterval = 0
    private var holdFrom = CGPoint.zero

    // the ball
    var bx: CGFloat = 120
    var by: CGFloat = CatRunnerState.ballR  // the middle of the ball, above the floor
    var bvx: CGFloat = 0
    var bvy: CGFloat = 0
    var playUntil: TimeInterval = 0         // the cat plays with the ball until here

    // the wand: your hand, the tip of the stick, and the end of the ribbon
    var handX: CGFloat = 0, handY: CGFloat = 0
    var tipX: CGFloat = 0, tipY: CGFloat = 0
    var lureX: CGFloat = 0, lureY: CGFloat = 0
    var lureVX: CGFloat = 0, lureVY: CGFloat = 0
    var swatAt: TimeInterval = -10          // when the cat last got the ribbon

    // the biscuit, the piles
    var treat: Treat?
    var poops: [Poop] = []

    // the hand
    private(set) var held: Held = .none
    private var samples: [(t: TimeInterval, x: CGFloat, y: CGFloat)] = []
    private var lastDrag: TimeInterval = 0

    // what happened (for the checks, and for anyone curious)
    var thrown = 0, caught = 0, fed = 0, cleaned = 0, swats = 0

    /// Which of the eight walking pictures to show now.
    var frame: Int { min(Self.frames - 1, Int((phase - phase.rounded(.down)) * Double(Self.frames))) }
    var ballHeld: Bool { held == .ball }
    var wandHeld: Bool { held == .wand }
    var ballMoving: Bool { ballOut && !ballHeld && (abs(bvx) > 20 || abs(bvy) > 20 || by > Self.ballR + 1.5) }
    private var ballLeft: CGFloat { Self.wandZone }
    private var ballRight: CGFloat { max(ballLeft + 1, width - Self.rightMargin) }

    /// A point in the strip's own coordinates (from the top left) as x along the strip and a height above the floor.
    func world(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: (height - floorInset) - p.y) }

    // MARK: the clock

    func step(now: TimeInterval, width: CGFloat, height: CGFloat = 80, floorInset: CGFloat = 4, scale: CGFloat = 1) {
        self.width = width; self.height = height; self.floorInset = floorInset; self.scale = scale
        let lo = Self.wandZone + 4, hi = max(lo + 1, width - Self.rightMargin - 4)
        if last == 0 {
            last = now; until = now + 7
            if !roster.contains(who) { who = roster[0] }
            x = min(max(width * 0.4, lo), hi)
            bx = min(max(width * 0.5, ballLeft), ballRight); by = Self.ballR
            let spots = [width * 0.17, width * 0.7]
            for (i, n) in roster.filter({ $0 != who }).enumerated() {
                lounge[n] = min(max(spots[i % spots.count], Self.wandZone + 34), hi - 10)      // a lying cat stays clear of where the wand lies
            }
            nextMischief = now + Double.random(in: 18...30, using: &rng)
        }
        let dt = CGFloat(min(max(now - last, 0), 0.1))
        last = now
        if held != .none, now - lastDrag > 2.5 { release(now: now) }      // a gesture that was cut off: let go
        moveBall(dt)
        moveTreat(dt, now)
        moveLure(dt)
        think(now, lo, hi, dt)
        hearts.removeAll { now - $0.t > 1.3 }
        prints.removeAll { now - $0.t > 2.4 }
        sparkles.removeAll { now - $0.t > 0.8 }
    }

    // MARK: the toys

    private func moveBall(_ dt: CGFloat) {
        guard ballOut, !ballHeld else { return }
        let r = Self.ballR
        bvy -= Self.gravity * dt
        bx += bvx * dt
        by += bvy * dt
        if by <= r {
            by = r
            if bvy < -(70 + Self.gravity * dt) { bvy = -bvy * 0.52; bvx *= 0.92 }          // a bounce (gravity's own pull in this one frame is not an impact)
            else {
                bvy = 0
                bvx *= max(0, 1 - 2.2 * dt)                          // rolling slows down
                if abs(bvx) < 5 { bvx = 0 }
            }
        }
        let ceiling = height - floorInset
        if by > ceiling - r { by = ceiling - r; bvy = -abs(bvy) * 0.4 }
        if bx < ballLeft { bx = ballLeft; bvx = abs(bvx) * 0.6 }
        if bx > ballRight { bx = ballRight; bvx = -abs(bvx) * 0.6 }
    }

    private func moveTreat(_ dt: CGFloat, _ now: TimeInterval) {
        guard var t = treat, !t.held, t.eatStart == nil else { return }
        if t.settledAt == nil {
            t.vy -= Self.gravity * dt
            t.x += t.vx * dt
            t.y += t.vy * dt
            t.vx *= max(0, 1 - 1.2 * dt)
            if t.y <= Self.treatRest {
                t.y = Self.treatRest
                if t.vy < -(150 + Self.gravity * dt) { t.vy = -t.vy * 0.3; t.vx *= 0.7 }
                else { t.vy = 0; t.vx = 0; t.settledAt = now }
            }
            t.x = min(max(t.x, Self.wandZone), width - Self.rightMargin)
        }
        treat = t
    }

    /// The ribbon hangs from the tip of the stick on a string, swinging and lagging behind your hand.
    private func moveLure(_ dt: CGFloat) {
        guard wandHeld else { return }
        lureVY -= 800 * dt
        lureX += lureVX * dt
        lureY += lureVY * dt
        let dx = lureX - tipX, dy = lureY - tipY
        let d = max(0.001, (dx * dx + dy * dy).squareRoot())
        if d > Self.stringLength {                                   // the string is taut: pull back, and lose the speed that was pulling it away
            let nx = dx / d, ny = dy / d
            lureX = tipX + nx * Self.stringLength; lureY = tipY + ny * Self.stringLength
            let vn = lureVX * nx + lureVY * ny
            if vn > 0 { lureVX -= vn * nx; lureVY -= vn * ny }
        }
        let drag = max(0, 1 - 1.6 * dt)
        lureVX *= drag; lureVY *= drag
        if lureY < 4 { lureY = 4; if lureVY < 0 { lureVY = 0 } }
        lureX = min(max(lureX, 4), width - 4)
    }

    // MARK: your hand

    /// Pick up the ball. `p` is where you touched, in the strip's own coordinates (from the top left).
    func beginBall(at p: CGPoint, now: TimeInterval) {
        guard held == .none, ballOut else { return }
        if quick(.ball, now: now) { stow(.ball, now: now); return }          // a second quick click: back in the box
        held = .ball
        if mode == .pouncing && carrying { carrying = false; mode = .chasing; goal = .ball }
        let w = world(p)
        place(&bx, &by, w, Self.ballR)
        bvx = 0; bvy = 0
        samples = [(now, bx, by)]; lastDrag = now
        holdStart = now; holdFrom = CGPoint(x: bx, y: by)
    }

    /// Pick up the fish biscuit that is on the strip.
    func beginTreat(at p: CGPoint, now: TimeInterval) {
        guard held == .none, let existing = treat, existing.eatStart == nil else { return }       // nothing there, or too late: it is being eaten
        held = .treat
        let w = world(p)
        var t = existing
        t.held = true; t.settledAt = nil; t.vx = 0; t.vy = 0
        treat = t
        samples = [(now, w.x, w.y)]; lastDrag = now
        drag(to: p, now: now)
    }

    /// Take the wand. Your hand holds the bottom of the stick; the tip is up and to the right of it, and the ribbon hangs from the tip.
    func beginWand(at p: CGPoint, now: TimeInterval) {
        guard held == .none, wandOut else { return }
        if quick(.wand, now: now) { stow(.wand, now: now); return }
        held = .wand
        lastDrag = now
        setHand(world(p))
        holdStart = now; holdFrom = CGPoint(x: handX, y: handY)
        lureX = tipX; lureY = max(4, tipY - Self.stringLength); lureVX = 0; lureVY = 0
    }

    private func setHand(_ w: CGPoint) {
        handX = min(max(w.x, 8), width - 30)
        handY = min(max(w.y, 4), height - floorInset - 34)
        tipX = handX + 22; tipY = handY + 26
    }

    func drag(to p: CGPoint, now: TimeInterval) {
        guard held != .none else { return }
        let w = world(p)
        lastDrag = now
        switch held {
        case .ball:
            place(&bx, &by, w, Self.ballR)
            samples.append((now, bx, by))
        case .treat:
            guard var t = treat else { break }
            t.x = min(max(w.x, 8), width - Self.rightMargin + 2)
            t.y = min(max(w.y, Self.treatRest), height - floorInset - 8)
            treat = t
            samples.append((now, t.x, t.y))
        case .wand:
            setHand(w)
        case .none: break
        }
        samples.removeAll { now - $0.t > 0.15 }
    }

    /// Let go. The ball and the biscuit carry on with the speed of your hand; the wand goes back to its place.
    func release(now: TimeInterval) {
        guard held != .none else { return }
        var vx: CGFloat = 0, vy: CGFloat = 0
        let recent = samples.filter { now - $0.t <= 0.12 }
        if let a = recent.first, let b = recent.last, b.t - a.t > 0.015 {
            let d = CGFloat(b.t - a.t)
            vx = min(max((b.x - a.x) / d, -1000), 1000)
            vy = min(max((b.y - a.y) / d, -1000), 1000)
        }
        let (hx, hy) = held == .ball ? (bx, by) : (handX, handY)
        if held != .treat, now - holdStart < 0.3, hypot(hx - holdFrom.x, hy - holdFrom.y) < 6 {         // a click, not a throw: a second one puts it away
            lastTap[held == .ball ? .ball : .wand] = now
        }
        switch held {
        case .ball:
            bvx = vx; bvy = vy
            thrown += 1
            playUntil = max(playUntil, now + Self.playTime)
            if mode == .sitting || mode == .running || mode == .lounging { mode = .chasing; goal = .ball }
        case .treat:
            if var t = treat { t.held = false; t.vx = vx * 0.6; t.vy = vy * 0.6; t.settledAt = nil; treat = t }
        case .wand, .none: break
        }
        held = .none
        samples = []
    }

    /// Was there a quick click on this toy just before this one?
    private func quick(_ toy: Toy, now: TimeInterval) -> Bool {
        guard let t = lastTap[toy], now - t < 0.45 else { return false }
        lastTap[toy] = nil
        return true
    }

    // MARK: the toy box

    /// A click on a toy in the box: out it comes (the ball and the biscuit bounce up from `x`, in the strip's coordinates; the wand
    /// drops in at its place at the left end), or, if it is already out, back it goes. The biscuit just comes out.
    func toggle(_ toy: Toy, fromX x: CGFloat, now: TimeInterval) {
        switch toy {
        case .ball: if ballOut { stow(.ball, now: now) } else { toss(.ball, fromX: x, now: now) }
        case .wand: if wandOut { stow(.wand, now: now) } else { toss(.wand, fromX: x, now: now) }
        case .biscuit: toss(.biscuit, fromX: x, now: now)
        }
    }

    func toss(_ toy: Toy, fromX x: CGFloat, now: TimeInterval) {
        switch toy {
        case .ball:
            guard !ballOut else { return }
            ballOut = true; ballChanged = now
            bx = min(max(x, ballLeft), ballRight); by = Self.ballR
            let side: CGFloat = Bool.random(using: &rng) ? 1 : -1
            bvx = side * CGFloat(Double.random(in: 35...90, using: &rng)); bvy = 450
            playUntil = now + Self.playTime
            if mode == .sitting || mode == .running || mode == .lounging { mode = .chasing; goal = .ball }
        case .wand:
            guard !wandOut else { return }
            wandOut = true; wandChanged = now
        case .biscuit:
            guard treat == nil, held != .treat else { return }
            treat = Treat(x: min(max(x, Self.wandZone), width - Self.rightMargin), y: Self.treatRest + 4,
                          vx: CGFloat(Double.random(in: -30...30, using: &rng)), vy: 380, held: false)
        }
    }

    /// Back in the box. Whatever you were holding is let go, and the cat stops wanting it.
    func stow(_ toy: Toy, now: TimeInterval) {
        switch toy {
        case .ball:
            guard ballOut else { return }
            if held == .ball { held = .none; samples = [] }
            ballOut = false; ballChanged = now
            bvx = 0; bvy = 0; playUntil = 0
            if mode == .pouncing && goal == .ball { carrying = false; mode = .sitting; until = now + 1 }
            else if mode == .chasing && goal == .ball { endChase(now) }
        case .wand:
            guard wandOut else { return }
            if held == .wand { held = .none; samples = [] }
            wandOut = false; wandChanged = now
            if (mode == .pouncing || mode == .chasing) && goal == .wand { mode = .sitting; until = now + 1 }
        case .biscuit: break
        }
    }

    /// The cats on the strip (names, up to three; Settings has the chooser). The one that is out stays if it is still among them.
    func setRoster(_ chosen: [String], now: TimeInterval) {
        var r: [Int] = []
        for n in chosen { if let i = Self.names.firstIndex(of: n), !r.contains(i) { r.append(i) } }
        r = Array(r.prefix(Self.rosterMax))
        if r.isEmpty { r = Self.defaultRoster.compactMap { Self.names.firstIndex(of: $0) } }
        guard r != roster else { return }
        roster = r
        guard last != 0 else { return }                                  // not started yet: the first step lays them out
        if !r.contains(who) {
            who = r[0]
            carrying = false
            hearts.append((x, now))
            if mode == .sleeping || mode == .lounging { mode = .sitting; until = now + 1.5 }
        }
        lounge.removeValue(forKey: who)
        for n in Array(lounge.keys) where !r.contains(n) { lounge.removeValue(forKey: n) }
        let spots = [width * 0.17, width * 0.7, width * 0.43]
        for n in r where n != who && lounge[n] == nil {
            let free = spots.max { abs($0 - x) < abs($1 - x) } ?? x          // the spot furthest from the cat that is out
            let taken = Set(lounge.values.map { Int($0 / 20) })
            let pick = spots.filter { !taken.contains(Int($0 / 20)) }.max { abs($0 - x) < abs($1 - x) } ?? free
            lounge[n] = min(max(pick, Self.wandZone + 34), width - Self.rightMargin - 14)
            hearts.append((lounge[n] ?? x, now))
        }
    }

    private func place(_ x: inout CGFloat, _ y: inout CGFloat, _ w: CGPoint, _ r: CGFloat) {
        x = min(max(w.x, ballLeft), ballRight)
        y = min(max(w.y, r), height - floorInset - r)
    }

    /// A tap on the pile cleans it up (with a little sparkle).
    func clean(born: TimeInterval, now: TimeInterval) {
        guard let i = poops.firstIndex(where: { $0.born == born }) else { return }
        let p = poops.remove(at: i)
        cleaned += 1
        for k in 0..<5 { sparkles.append((p.x + CGFloat(k - 2) * 7, CGFloat(6 + (k % 2) * 8), now)) }
    }

    /// A tap on the cat that is out: it jumps and sends a heart; one that was asleep or lazing wakes up and sits for a moment.
    func poke(now: TimeInterval) {
        hop(now, 13)
        hearts.append((x, now))
        if mode == .sleeping || mode == .lounging { mode = .sitting; until = now + 2.5 }
    }

    /// A tap on a cat that is lying down: it gets up and goes out, and the one that was out lies down where it stood.
    func wake(_ n: Int, now: TimeInterval) {
        guard let lx = lounge[n], n != who else { return }
        hearts.append((lx, now))
        lounge[who] = x
        lounge.removeValue(forKey: n)
        who = n; x = lx
        carrying = false
        mode = .sitting; until = now + 2.2
        hop(now, 10)
    }

    private func hop(_ now: TimeInterval, _ amp: CGFloat) { jumpedAt = now; jumpAmp = amp }

    /// How high the cat is above the line right now (a hop lasts half a second; the walk cycle has its own small bob).
    func lift(now: TimeInterval) -> CGFloat {
        let j = now - jumpedAt
        return j >= 0 && j < 0.5 ? CGFloat(sin(j / 0.5 * .pi)) * jumpAmp : 0
    }

    /// The places that react to the mouse (for the window on the Mac, which lets everything else through). The whole strip while
    /// something is in your hand. In the strip's own coordinates, from the top left.
    func hotRects() -> [CGRect] {
        if held != .none { return [CGRect(x: 0, y: 0, width: width, height: height)] }
        let floor = height - floorInset
        var r = [CGRect(x: x - 20, y: floor - 48, width: 40, height: 50)]
        if ballOut { r.append(CGRect(x: bx - Self.ballR - 6, y: floor - by - Self.ballR - 6, width: Self.ballR * 2 + 12, height: Self.ballR * 2 + 12)) }
        if wandOut { r.append(CGRect(x: 0, y: floor - 40, width: Self.wandZone + 2, height: 44)) }
        if let t = treat, t.eatStart == nil { r.append(CGRect(x: t.x - 14, y: floor - t.y - 14, width: 28, height: 28)) }
        for p in poops { r.append(CGRect(x: p.x - 14, y: floor - 28, width: 28, height: 30)) }
        for (_, lx) in lounge { r.append(CGRect(x: lx - 26, y: floor - 40, width: 52, height: 42)) }
        return r
    }

    // MARK: the cat's mind

    private func think(_ now: TimeInterval, _ lo: CGFloat, _ hi: CGFloat, _ dt: CGFloat) {
        // what interrupts a quiet cat: a biscuit (even in its sleep), the wand, or the ball
        if mode != .eating && mode != .pouncing {
            if let t = treat, !t.held, let s = t.settledAt, t.eatStart == nil, now - s > (mode == .sleeping ? 1.2 : 0.15) {
                mode = .chasing; goal = .treat
            } else if mode != .sleeping && wandOut && wandHeld {
                mode = .chasing; goal = .wand
            } else if mode != .sleeping && mode != .chasing && ballOut && (ballHeld || now < playUntil || ballMoving) {
                mode = .chasing; goal = .ball
            }
        }
        switch mode {
        case .running:
            let zoom = now < zoomUntil
            walk(zoom ? Self.zoomSpeed : Self.speed, dt, now)
            if x >= hi || x <= lo {
                x = min(max(x, lo), hi); dir = -dir
                if !zoom && Double.random(in: 0..<1, using: &rng) < 0.35 { rest(now, lazy: Double.random(in: 0..<1, using: &rng) < 0.4) }
            } else if !zoom && now >= until {
                restSomehow(now)
            }
            if mode == .running && now >= nextMischief {                   // up to some mischief
                nextMischief = now + Double.random(in: 25...45, using: &rng)
                if ballOut && Double.random(in: 0..<1, using: &rng) < 0.55 { playUntil = now + 8 } else { zoomUntil = now + 2.4 }
            }
        case .sitting:
            if now >= until { run(now, flip: Double.random(in: 0..<1, using: &rng) < 0.5) }
        case .lounging:
            if now - lastPurr > 5 { lastPurr = now; hearts.append((x, now)) }                  // purring
            if now >= until { run(now, flip: Double.random(in: 0..<1, using: &rng) < 0.5) }
        case .sleeping:
            if now >= until {                                                                  // the next cat gets up; this one stays lying here
                let at = roster.firstIndex(of: who) ?? 0
                let n = roster[(at + 1) % roster.count]
                if n != who, let lx = lounge.removeValue(forKey: n) { lounge[who] = x; who = n; x = lx }
                run(now, flip: x > width / 2)
            }
        case .chasing:
            chase(now, lo, hi, dt)
        case .pouncing:
            if goal == .ball {
                if carrying { bx = x + dir * 14; by = Self.ballR + 4; bvx = 0; bvy = 0 }
                if now >= pounceEnd { bat(now) }
            } else if now >= pounceEnd {
                if goal == .wand && wandHeld { mode = .chasing } else { mode = .sitting; until = now + 1.5 }
            }
        case .eating:
            if let t = treat, t.eatStart != nil, now >= eatAt {
                treat = nil; fed += 1
                hearts.append((x + dir * 8, now))
                if poopDue == nil { poopDue = now + Double.random(in: 18...30, using: &rng) }
            }
            if now >= until { mode = .sitting; until = now + 1.3 }
        }
        if let due = poopDue, now >= due, mode == .running || mode == .sitting || mode == .lounging {          // after a while it leaves a little pile
            poopDue = nil
            if poops.count < 3 { poops.append(Poop(x: min(max(x - dir * 16, lo), hi), born: now)) }
            mode = .sitting; until = now + 1.5
        }
    }

    private func walk(_ v: CGFloat, _ dt: CGFloat, _ now: TimeInterval) {
        x += dir * v * dt
        phase += Double(v * dt / Self.stride)
        let h = Int(phase * 2)
        if h != step2 {                                  // a paw lands twice in a stride: a faint print behind the cat
            step2 = h
            prints.append((x - dir * 12, now, h % 2 == 0))
            if prints.count > 7 { prints.removeFirst() }
        }
    }

    private func chase(_ now: TimeInterval, _ lo: CGFloat, _ hi: CGFloat, _ dt: CGFloat) {
        var tx: CGFloat
        switch goal {
        case .treat:
            guard let t = treat, !t.held else { endChase(now); return }
            tx = t.x
        case .ball:
            guard ballOut, ballHeld || now < playUntil || ballMoving else { endChase(now); return }
            tx = bx + (ballMoving ? bvx * 0.18 : 0)
        case .wand:
            guard wandOut, wandHeld else { endChase(now); return }
            tx = lureX + lureVX * 0.12
        }
        tx = min(max(tx, lo), hi)
        let d = tx - x
        if abs(d) > 3 {
            dir = d > 0 ? 1 : -1
            let v = min(Self.chaseSpeed, abs(d) / max(dt, 0.001))        // no overshoot
            walk(v, dt, now)
        }
        switch goal {
        case .treat:
            if let t = treat, t.settledAt != nil, abs(x - t.x) < 12 {
                mode = .eating; until = now + 1.9; eatAt = now + 0.5
                treat?.eatStart = now
                dir = t.x >= x ? 1 : -1
            }
        case .ball:
            if !ballHeld, now >= noPounceUntil, abs(x - bx) <= Self.reach, by - Self.ballR <= Self.reachUp { pounce(now) }
        case .wand:
            guard now >= noPounceUntil, abs(x - lureX) <= Self.reach + 6 else { break }
            if lureY <= Self.reachUp + 14 {
                swat(now, jump: 10)
            } else if lureY <= 66 && now - jumpedAt > 0.8 {                  // leaps for a high one
                swat(now, jump: 22)
            }
        }
    }

    private func swat(_ now: TimeInterval, jump: CGFloat) {
        swats += 1
        swatAt = now
        mode = .pouncing
        pounceEnd = now + 0.45
        noPounceUntil = now + 0.9
        hop(now, jump)
        dir = lureX >= x ? 1 : -1
        lureVX += dir * 140; lureVY += 90                                  // the ribbon flicks away
        hearts.append((x, now))
    }

    private func endChase(_ now: TimeInterval) {
        mode = .sitting
        until = now + Double.random(in: 1.5...2.6, using: &rng)
    }

    private func pounce(_ now: TimeInterval) {
        carrying = ballMoving
        if carrying { caught += 1 }
        mode = .pouncing
        pounceEnd = now + (carrying ? 0.85 : 0.4)
        hop(now, by - Self.ballR > 14 ? 18 : 10)
        dir = bx >= x ? 1 : -1
    }

    /// The cat flicks the ball away (mostly towards the room there is, sometimes the other way) and, while it still wants to play, goes after it.
    private func bat(_ now: TimeInterval) {
        carrying = false
        let toward: CGFloat = x < width / 2 ? 1 : -1
        let d: CGFloat = Double.random(in: 0..<1, using: &rng) < 0.25 ? -toward : toward
        bx = min(max(x + d * 14, ballLeft), ballRight)
        by = max(by, Self.ballR + 2)
        bvx = d * CGFloat(Double.random(in: 140...250, using: &rng))
        bvy = CGFloat(Double.random(in: 150...320, using: &rng))
        dir = d
        hop(now, 8)
        noPounceUntil = now + 0.6
        if now < playUntil { mode = .chasing; goal = .ball } else { mode = .sitting; until = now + 2.2 }
    }

    /// After a stroll: a lie-down for a lazy while, a nap, or just sitting for a moment.
    private func restSomehow(_ now: TimeInterval) {
        let r = Double.random(in: 0..<1, using: &rng)
        if r < 0.3 { rest(now, sleep: true) } else { rest(now, lazy: r < 0.65) }
    }

    private func rest(_ now: TimeInterval, lazy: Bool) {
        mode = lazy ? .lounging : .sitting
        until = now + (lazy ? Double.random(in: 6...11, using: &rng) : Double.random(in: 2.2...3.8, using: &rng))
        if lazy { lastPurr = now }
    }

    private func rest(_ now: TimeInterval, sleep: Bool) {
        mode = .sleeping
        until = now + Double.random(in: 7...10, using: &rng)
    }

    private func run(_ now: TimeInterval, flip: Bool) {
        mode = .running
        if flip { dir = -dir }
        until = now + Double.random(in: 7...12, using: &rng)
    }
}

struct CatRunner: View {
    /// Height of the walking cat, in points; a sitting cat is as tall. The line the paws stand on is `floorInset` above the
    /// bottom of the view (4 in a top bar, 1 for the perch on the window's edge).
    static let catHeight: CGFloat = 44
    /// Points for one pixel of the walk strip, whose cell is as tall as `catHeight`.
    static func unit(_ name: String) -> CGFloat {
        catHeight / (CatRunnerSkin.picture("walk-\(name)")?.size.height ?? 155)
    }
    /// The sitting and sleeping pictures are drawn larger than the walk strip (measured 10 Nov 2026: the cat fills about 148 px of
    /// the walk cell, 205 px of the sitting picture and 305 x 185 px of the sleeping one). At one scale a sleeping cat came out almost
    /// three times as wide as the same cat walking. These bring every pose to one cat: sitting as tall as walking, asleep a low loaf
    /// about one and a half times as wide as the walker.
    static let sitScale: CGFloat = 0.72
    static let sleepScale: CGFloat = 0.52
    static func sitUnit(_ name: String) -> CGFloat { unit(name) * sitScale }
    static func sleepUnit(_ name: String) -> CGFloat { unit(name) * sleepScale }
    static let space = "cattrack"
    /// The least and the most the cats can be drawn bigger by (a preference outside this is held to it).
    static let scaleRange: ClosedRange<CGFloat> = 0.5...2
    var floorInset: CGFloat = 4
    /// How much bigger than the usual the cats are drawn (`CatSize`). 1 is exactly the way the strip has always been drawn; anything
    /// else plays the strip in smaller points (the width and the height divided by it) and draws that, scaled up from its top left
    /// corner, over the room the host gave it. The pointer and the finger land in the strip's own points (the named space is inside
    /// the scaling), so every toy and cat answers to a touch wherever it is drawn.
    var scale: CGFloat = 1
    @State private var state: CatRunnerState

    init(state: CatRunnerState? = nil, floorInset: CGFloat = 4, scale: CGFloat = 1) {
        _state = State(initialValue: state ?? CatRunnerState.shared)
        self.floorInset = floorInset
        self.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    var body: some View {
        if CatRunnerSkin.reduceMotion {
            EmptyView()
        } else {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let now = ctx.date.timeIntervalSinceReferenceDate
                    if scale == 1 {
                        let _ = state.step(now: now, width: geo.size.width, height: geo.size.height, floorInset: floorInset)
                        scene(now: now, height: geo.size.height, inset: floorInset)
                    } else {
                        let w = geo.size.width / scale, h = geo.size.height / scale, inset = floorInset / scale
                        let _ = state.step(now: now, width: w, height: h, floorInset: inset, scale: scale)
                        scene(now: now, height: h, inset: inset)
                            .frame(width: w, height: h, alignment: .topLeading)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .onAppear { state.setRoster(CatRunnerSkin.roster, now: clock()) }
            .onReceive(NotificationCenter.default.publisher(for: .catRosterChanged)) { _ in state.setRoster(CatRunnerSkin.roster, now: clock()) }
        }
    }

    private func clock() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    @ViewBuilder
    private func scene(now: TimeInterval, height: CGFloat, inset: CGFloat) -> some View {
        let s = state
        let floor = height - inset                               // the line the paws stand on
        ZStack(alignment: .topLeading) {
            printsLayer(s, now: now, floor: floor)
            loungeLayer(s, now: now, floor: floor)
            poopsLayer(s, now: now, floor: floor)
            treatLayer(s, now: now, floor: floor)
            catLayer(s, now: now, floor: floor)
            heartsLayer(s, now: now, floor: floor)
            ballLayer(s, now: now, floor: floor)
            wandLayer(s, now: now, floor: floor)
            sparklesLayer(s, now: now, floor: floor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    // MARK: layers

    private func printsLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        ForEach(Array(s.prints.enumerated()), id: \.offset) { _, p in
            Image(systemName: "pawprint.fill").font(.system(size: 7))
                .foregroundColor(CatRunnerSkin.printColor).opacity(max(0, 0.45 * (1 - (now - p.t) / 2.4)))
                .rotationEffect(.degrees(s.dir > 0 ? 90 : -90))
                .position(x: p.x, y: floor - (p.up ? 5 : 1))
        }
    }

    private func heartsLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        ForEach(Array(s.hearts.enumerated()), id: \.offset) { _, h in
            let age = now - h.t
            Image(systemName: "heart.fill").font(.system(size: 11 + CGFloat(age) * 3))
                .foregroundColor(Color(red: 0.96, green: 0.45, blue: 0.58))
                .opacity(max(0, 1 - age / 1.3))
                .position(x: h.x + CGFloat(sin(age * 5)) * 4, y: floor - CatRunner.catHeight - 6 - CGFloat(age) * 16)
        }
    }

    private func sparklesLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        ForEach(Array(s.sparkles.enumerated()), id: \.offset) { _, k in
            let age = now - k.t
            Image(systemName: "star.fill").font(.system(size: 8 + CGFloat(sin(age / 0.8 * .pi)) * 5))
                .foregroundColor(Color(red: 1, green: 0.82, blue: 0.40))
                .opacity(max(0, 1 - age / 0.8))
                .position(x: k.x, y: floor - k.y - CGFloat(age) * 26)
        }
    }

    /// The two cats that are not out, lying down and breathing slowly. A tap gets one up.
    private func loungeLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        ForEach(s.lounge.keys.sorted(), id: \.self) { n in
            let lx = s.lounge[n] ?? 0
            if let pic = CatRunnerSkin.picture("runner-sleep-\(CatRunnerState.names[n])") {
                let w = pic.size.width * CatRunner.sleepUnit(CatRunnerState.names[n])
                let breathe = 1 + 0.03 * CGFloat(sin(now * 1.3 + Double(n) * 2.1))
                pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: w)
                    .scaleEffect(x: 1, y: breathe, anchor: .bottom)
                    .scaleEffect(x: n == 1 ? -1 : 1, y: 1)
                    .contentShape(Rectangle())
                    .onTapGesture { s.wake(n, now: clock()) }
                    .position(x: lx, y: floor - w * pic.size.height / pic.size.width / 2 + 2)
            }
        }
    }

    private func poopsLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        ForEach(s.poops, id: \.born) { p in
            let w: CGFloat = 22
            let pop = min(1, (now - p.born) / 0.25)                   // pops in
            Group {
                if let pic = CatRunnerSkin.picture("toy-poop") {
                    pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: w)
                } else {
                    Text("💩").font(.system(size: 16))
                }
            }
            .scaleEffect(0.4 + 0.6 * CGFloat(pop), anchor: .bottom)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onTapGesture { s.clean(born: p.born, now: clock()) }
            .position(x: p.x, y: floor - 12)
        }
    }

    @ViewBuilder
    private func treatLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        if let t = s.treat {
            let w: CGFloat = 18
            let nibble = t.eatStart.map { max(0, 1 - CGFloat(now - $0) / 0.5) } ?? 1          // gets eaten
            Group {
                if let pic = CatRunnerSkin.picture("toy-fish") {
                    pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: w)
                } else {
                    Text("🐟").font(.system(size: 13))
                }
            }
            .rotationEffect(.degrees(t.settledAt == nil ? Double(t.x) * 3 : -8))                  // it spins while it is carried or falling
            .scaleEffect(nibble)
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
            .gesture(treatDrag(s))
            .position(x: t.x, y: floor - t.y)
        }
    }

    @ViewBuilder
    private func ballLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        let age = now - s.ballChanged
        let pop: CGFloat = s.ballOut ? min(1, 0.3 + CGFloat(age) / 0.18 * 0.7) : max(0, 1 - CGFloat(age) / 0.18)      // it pops out, and shrinks back in
        if s.ballOut || pop > 0 { ballBody(s, floor: floor, pop: pop) }
    }

    @ViewBuilder
    private func ballBody(_ s: CatRunnerState, floor: CGFloat, pop: CGFloat) -> some View {
        let r = CatRunnerState.ballR
        let up = max(0, s.by - r)
        Ellipse().fill(Color.black.opacity(0.13))                                  // its shadow on the floor
            .frame(width: 20 * max(0.4, 1 - up / 90) * pop, height: 4)
            .position(x: s.bx, y: floor)
        Group {
            if let pic = CatRunnerSkin.picture("toy-ball") {
                pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: r * 2 * (s.ballHeld ? 1.12 : 1))
            } else {
                Circle().fill(CatRunnerSkin.printColor).frame(width: r * 2, height: r * 2)
            }
        }
        .rotationEffect(.radians(Double(s.bx / r)))                                // it turns as it rolls
        .scaleEffect(pop)
        .frame(width: r * 2 + 10, height: r * 2 + 10)
        .contentShape(Circle())
        .gesture(ballDrag(s), including: s.ballOut ? .all : .subviews)
        .position(x: s.bx, y: floor - s.by)
    }

    /// The wand: lying at the left end when nobody has it; in your hand, the ribbon swings from the tip on a string.
    @ViewBuilder
    private func wandLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        let age = now - s.wandChanged
        let drop: CGFloat = s.wandOut ? CGFloat(abs(sin(age * 11))) * 34 * max(0, 1 - CGFloat(age) / 0.55) : 0      // it bounces in from above
        let pop: CGFloat = s.wandOut ? 1 : max(0, 1 - CGFloat(age) / 0.18)                                         // and shrinks back into the box
        if s.wandOut || pop > 0 { wandBody(s, now: now, floor: floor, drop: drop, pop: pop) }
    }

    @ViewBuilder
    private func wandBody(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat, drop: CGFloat, pop: CGFloat) -> some View {
        let held = s.wandHeld
        let hand = CGPoint(x: held ? s.handX : 9, y: floor - (held ? s.handY : 2) - drop)
        let tip = CGPoint(x: held ? s.tipX : 27, y: floor - (held ? s.tipY : 26) - drop)
        let lure = held ? CGPoint(x: s.lureX, y: floor - s.lureY)
                        : CGPoint(x: tip.x + CGFloat(sin(now * 2.2)) * 2.5, y: tip.y + 11)
        let swat = max(0, 1 - CGFloat(now - s.swatAt) / 0.4)                       // the ribbon shivers when the cat gets it
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: hand); p.addLine(to: tip) }
                .stroke(CatRunnerSkin.zColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            Path { p in p.move(to: tip); p.addLine(to: lure) }
                .stroke(CatRunnerSkin.zColor.opacity(0.7), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            Path { p in                                                            // the ribbon, a wavy tail under the star
                p.move(to: lure)
                for i in 1...6 {
                    let t = CGFloat(i) / 6
                    p.addLine(to: CGPoint(x: lure.x + CGFloat(sin(now * 7 + Double(i))) * (2 + 3 * swat) * t, y: lure.y + 4 + 13 * t))
                }
            }
            .stroke(CatRunnerSkin.printColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Image(systemName: "star.fill").font(.system(size: 10 + 3 * swat))
                .foregroundColor(Color(red: 1, green: 0.82, blue: 0.40))
                .position(lure)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(Double(pop))
        .allowsHitTesting(false)
        Color.white.opacity(0.001)                                                // where you take hold of it (its place, at the left end)
            .frame(width: CatRunnerState.wandZone, height: 40)
            .contentShape(Rectangle())
            .gesture(wandDrag(s), including: s.wandOut ? .all : .subviews)
            .position(x: CatRunnerState.wandZone / 2, y: floor - 18)
    }

    @ViewBuilder
    private func catLayer(_ s: CatRunnerState, now: TimeInterval, floor: CGFloat) -> some View {
        let name = CatRunnerState.names[s.who]
        let air = s.lift(now: now)
        switch s.mode {
        case .sleeping, .lounging:
            if let pic = CatRunnerSkin.picture("runner-sleep-\(name)") {
                let w = pic.size.width * CatRunner.sleepUnit(name)
                let breathe = 1 + (s.mode == .sleeping ? 0.035 : 0.025) * CGFloat(sin(now * (s.mode == .sleeping ? 1.7 : 1.2)))
                pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: w)
                    .scaleEffect(x: 1, y: breathe, anchor: .bottom)
                    .scaleEffect(x: s.dir, y: 1)
                    .contentShape(Rectangle())
                    .onTapGesture { s.poke(now: clock()) }
                    .position(x: s.x, y: floor - w * pic.size.height / pic.size.width / 2 + 2)
                if s.mode == .sleeping {
                    ForEach(0..<3, id: \.self) { i in
                        let t = (now * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Text("z").font(CatRunnerSkin.zFont(11 + CGFloat(i) * 2)).foregroundColor(CatRunnerSkin.zColor)
                            .opacity(sin(t * .pi))
                            .position(x: s.x + 14 + CGFloat(t) * 12, y: floor - 16 - CGFloat(t) * 12)
                    }
                }
            }
        case .sitting, .eating:
            if let pic = CatRunnerSkin.picture("runner-\(name)") {
                let h = pic.size.height * CatRunner.sitUnit(name)
                let w = h * pic.size.width / pic.size.height
                let eating = s.mode == .eating
                let nod = eating ? CGFloat(sin(now * 11)) * 5 : 0                           // head down at the biscuit
                pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: w, height: h)
                    .scaleEffect(x: s.dir, y: 1)
                    .rotationEffect(.degrees(Double(eating ? 5 + nod : 0) * Double(s.dir)), anchor: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { s.poke(now: clock()) }
                    .position(x: s.x, y: floor - h / 2 - air)
            }
        case .running, .chasing, .pouncing:
            let h = CatRunner.catHeight
            if let pic = CatRunnerSkin.picture("walk-\(name)") {
                let w = h * (pic.size.width / CGFloat(CatRunnerState.frames)) / pic.size.height
                let f = s.mode == .pouncing ? 2 : s.frame
                let tilt = s.mode == .pouncing ? -9 * Double(s.dir) : 0
                pic.image.resizable().interpolation(.high)
                    .frame(width: w * CGFloat(CatRunnerState.frames), height: h)
                    .offset(x: (CGFloat(CatRunnerState.frames - 1) / 2 - CGFloat(f)) * w)         // the picture of the stride we are in
                    .frame(width: w, height: h)
                    .clipped()
                    .scaleEffect(x: s.dir, y: 1)
                    .rotationEffect(.degrees(tilt), anchor: .bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { s.poke(now: clock()) }
                    .position(x: s.x, y: floor - h / 2 - air)
            }
        }
    }

    // MARK: gestures

    private func ballDrag(_ s: CatRunnerState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let t = clock()
                if s.held == .none { s.beginBall(at: v.location, now: t) }
                s.drag(to: v.location, now: t)
            }
            .onEnded { _ in s.release(now: clock()) }
    }

    private func treatDrag(_ s: CatRunnerState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let t = clock()
                if s.held == .none { s.beginTreat(at: v.location, now: t) }
                s.drag(to: v.location, now: t)
            }
            .onEnded { _ in s.release(now: clock()) }
    }

    private func wandDrag(_ s: CatRunnerState) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let t = clock()
                if s.held == .none { s.beginWand(at: v.location, now: t) }
                s.drag(to: v.location, now: t)
            }
            .onEnded { _ in s.release(now: clock()) }
    }
}


/// The tiny toy box (10 Nov 2026): the toys and the food are kept in the app, not lying about on the strip. Click one and it bounces out
/// of the app onto the strip above (the cat goes for it); click it again, or double-click it on the strip, and it goes back in. The
/// fish biscuit comes out one at a time and is eaten. `stripInset` is how far along the window the strip starts (the Mac's strip is a
/// little narrower than its window), so the toy comes out right above its slot.
struct CatToyBox: View {
    @ObservedObject private var state: CatRunnerState
    private let stripInset: CGFloat

    init(state: CatRunnerState = CatRunnerState.shared, stripInset: CGFloat = 0) {
        self.state = state
        self.stripInset = stripInset
    }

    var body: some View {
        if CatRunnerSkin.reduceMotion {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Text("Toys").font(CatRunnerSkin.zFont(14)).foregroundColor(CatRunnerSkin.zColor)
                Spacer(minLength: 4)
                slot(.ball, title: "ball", out: state.ballOut) { picture("toy-ball", fallback: AnyView(Circle().fill(CatRunnerSkin.printColor))) }
                slot(.wand, title: "wand", out: state.wandOut) { WandIcon() }
                slot(.biscuit, title: "fish biscuit", out: false) { picture("toy-fish", fallback: AnyView(Text("🐟").font(.system(size: 16)))) }
            }
        }
    }

    private func picture(_ name: String, fallback: AnyView) -> some View {
        Group {
            if let pic = CatRunnerSkin.picture(name) {
                pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
            } else {
                fallback.frame(width: 18, height: 18)
            }
        }
    }

    private func slot<Icon: View>(_ toy: CatRunnerState.Toy, title: String, out: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        let tint = CatRunnerSkin.printColor
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let content = icon()
        return GeometryReader { g in
            Button {
                // the slot's place along the strip, in the strip's own points (the strip may be drawn bigger or smaller than they are)
                state.toggle(toy, fromX: (g.frame(in: .global).midX - stripInset) / max(state.scale, 0.1), now: Date().timeIntervalSinceReferenceDate)
            } label: {
                ZStack {
                    shape.fill(tint.opacity(out ? 0.04 : 0.14))
                    shape.strokeBorder(tint.opacity(out ? 0.4 : 0.2), style: StrokeStyle(lineWidth: 1, dash: out ? [3, 3] : []))
                    content.opacity(out ? 0.25 : 1)
                    if out { Image(systemName: "arrow.uturn.down").font(.system(size: 12, weight: .bold)).foregroundColor(CatRunnerSkin.zColor) }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 34, height: 34)
        .help(out ? "Put the \(title) back in the box" : toy == .biscuit ? "Give the cats a fish biscuit" : "Take the \(title) out to play")
        .accessibilityLabel(out ? "Put the \(title) back" : toy == .biscuit ? "Give a fish biscuit" : "Take out the \(title)")
    }
}

/// The wand as a little icon: a stick with a ribbon and a star.
struct WandIcon: View {
    var body: some View {
        ZStack {
            Path { p in p.move(to: CGPoint(x: 5, y: 21)); p.addLine(to: CGPoint(x: 16, y: 8)) }
                .stroke(CatRunnerSkin.zColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 16, y: 8)); p.addLine(to: CGPoint(x: 19, y: 12))
                p.addCurve(to: CGPoint(x: 18, y: 21), control1: CGPoint(x: 23, y: 15), control2: CGPoint(x: 15, y: 17))
            }
            .stroke(CatRunnerSkin.printColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(Color(red: 1, green: 0.82, blue: 0.40)).position(x: 17, y: 6)
        }
        .frame(width: 24, height: 24)
    }
}

/// Settings: which cats live on the strip. Up to three at a time; tap a cat to bring it in or send it away (one always stays).
struct CatChooser: View {
    @Binding var selection: [String]
    #if os(iOS)
    private static let cellMin: CGFloat = 90        // three across on a phone, two rows
    #else
    private static let cellMin: CGFloat = 62
    #endif

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellMin), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(CatRunnerState.names.enumerated()), id: \.offset) { i, name in chip(name, CatRunnerState.titles[i]) }
        }
    }

    private func chip(_ name: String, _ title: String) -> some View {
        let on = selection.contains(name)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { toggle(name) } label: {
            VStack(spacing: 3) {
                Group {
                    if let pic = CatRunnerSkin.picture("runner-\(name)") {
                        pic.image.resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 42)
                    } else {
                        Text("🐱").font(.system(size: 28)).frame(height: 42)
                    }
                }
                .opacity(on ? 1 : 0.55)
                Text(title).font(CatRunnerSkin.labelFont(11.5)).foregroundColor(on ? CatRunnerSkin.printColor : CatRunnerSkin.zColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(shape.fill(CatRunnerSkin.printColor.opacity(on ? 0.16 : 0.05)))
            .overlay(shape.strokeBorder(CatRunnerSkin.printColor.opacity(on ? 0.7 : 0.15), lineWidth: on ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(on ? ", on the strip" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ name: String) {
        var s = selection
        if let i = s.firstIndex(of: name) {
            guard s.count > 1 else { return }                           // one cat always stays
            s.remove(at: i)
        } else {
            s.append(name)
            if s.count > CatRunnerState.rosterMax { s.removeFirst() }    // the one that has been there longest makes room
        }
        selection = s
        NotificationCenter.default.post(name: .catRosterChanged, object: nil)
    }
}
