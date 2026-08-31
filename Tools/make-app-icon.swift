import AppKit
import CoreGraphics

// The app icon: a wedge, drawn rather than drafted, so it is reproducible and
// versioned. 1024², three appearances (light / dark / tinted).
//
// The club is built in its own frame — shaft vertical, head at the bottom — and
// then rotated, measured and *fitted* to a safe rect, so nothing runs off the
// canvas and the composition is centred by construction rather than by eye.

enum Look { case light, dark, tinted }

struct Stroke { var path: CGPath; var width: CGFloat; var cap: CGLineCap = .round }

func clubPaths() -> (head: CGPath, sole: CGPath, shaft: CGPath, strokes: [Stroke],
                     grip: Stroke, grooves: [CGPath], grooveWidth: CGFloat) {
    // A wedge face-on: a straight leading edge, a **high toe**, a level topline
    // dropping toward the heel, and a hosel rising off the heel. The proportions
    // are what carry it — a head this size on a short shaft reads as a mallet
    // putter, which is what the first attempt drew.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 26, y: 18))                       // heel, at the sole
    head.addLine(to: CGPoint(x: 300, y: 8))                    // leading edge, straight
    head.addCurve(to: CGPoint(x: 344, y: 132),                 // toe: tall and rounded
                  control1: CGPoint(x: 340, y: 12), control2: CGPoint(x: 352, y: 72))
    head.addCurve(to: CGPoint(x: 250, y: 214),
                  control1: CGPoint(x: 338, y: 178), control2: CGPoint(x: 300, y: 208))
    head.addLine(to: CGPoint(x: 96, y: 176))                   // topline, dropping to the heel
    head.addCurve(to: CGPoint(x: 26, y: 18),
                  control1: CGPoint(x: 52, y: 168), control2: CGPoint(x: 20, y: 96))
    head.closeSubpath()

    // The sole — a wedge's is wide and it is the cue that separates one from an
    // iron at icon size.
    let sole = CGMutablePath()
    sole.move(to: CGPoint(x: 34, y: 26))
    sole.addLine(to: CGPoint(x: 302, y: 16))

    // **Hosel and shaft are one tapered shape**, not two strokes.
    //
    // Drawn as a wide stroke into a narrow one they meet in a visible step, and at
    // icon size a step in a silhouette reads as two objects — which is what the
    // second attempt looked like. One filled quad from the heel to the grip end,
    // 46 points wide where it enters the head and 24 at the top, has no join to
    // get wrong.
    let heel = CGPoint(x: 74, y: 96), butt = CGPoint(x: 306, y: 1240)
    let d = CGPoint(x: butt.x - heel.x, y: butt.y - heel.y)
    let len = (d.x * d.x + d.y * d.y).squareRoot()
    let n = CGPoint(x: d.y / len, y: -d.x / len)          // unit normal
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: heel.x + n.x * 23, y: heel.y + n.y * 23))
    shaft.addLine(to: CGPoint(x: butt.x + n.x * 12, y: butt.y + n.y * 12))
    shaft.addLine(to: CGPoint(x: butt.x - n.x * 12, y: butt.y - n.y * 12))
    shaft.addLine(to: CGPoint(x: heel.x - n.x * 23, y: heel.y - n.y * 23))
    shaft.closeSubpath()

    let grip = CGMutablePath()
    grip.move(to: CGPoint(x: 260, y: 1010))
    grip.addLine(to: CGPoint(x: 308, y: 1252))

    var grooves: [CGPath] = []
    for i in 0..<7 {
        let y = 56 + CGFloat(i) * 21
        let g = CGMutablePath()
        g.move(to: CGPoint(x: 104 + CGFloat(i) * 4, y: y))
        g.addLine(to: CGPoint(x: 306 - CGFloat(i) * 9, y: y + 1))
        grooves.append(g)
    }
    return (head, sole, shaft, [], Stroke(path: grip, width: 50), grooves, 11)
}

func draw(_ look: Look) -> CGImage {
    let S: CGFloat = 1024
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let top: CGColor, bottom: CGColor, metal: CGColor, metalDark: CGColor, grip: CGColor
    switch look {
    case .light:
        top    = CGColor(red: 0.298, green: 0.506, blue: 0.349, alpha: 1)   // fairway
        bottom = CGColor(red: 0.113, green: 0.184, blue: 0.137, alpha: 1)   // roughDeep
        metal  = CGColor(red: 0.957, green: 0.965, blue: 0.949, alpha: 1)   // bone
        metalDark = CGColor(red: 0.706, green: 0.741, blue: 0.714, alpha: 1)
        grip   = CGColor(red: 0.098, green: 0.121, blue: 0.110, alpha: 1)
    case .dark:
        top    = CGColor(red: 0.145, green: 0.235, blue: 0.176, alpha: 1)   // rough
        bottom = CGColor(red: 0.043, green: 0.070, blue: 0.055, alpha: 1)
        metal  = CGColor(red: 0.910, green: 0.925, blue: 0.906, alpha: 1)
        metalDark = CGColor(red: 0.640, green: 0.672, blue: 0.650, alpha: 1)
        grip   = CGColor(red: 0.062, green: 0.078, blue: 0.070, alpha: 1)
    case .tinted:
        top    = CGColor(gray: 0.32, alpha: 1)
        bottom = CGColor(gray: 0.10, alpha: 1)
        metal  = CGColor(gray: 1.00, alpha: 1)
        metalDark = CGColor(gray: 0.72, alpha: 1)
        grip   = CGColor(gray: 0.06, alpha: 1)
    }
    let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    let (head, sole, shaft, strokes, gripStroke, grooves, grooveWidth) = clubPaths()

    // Rotate, then fit **the head** — not the whole club — into a target rect,
    // and let the shaft run off the top corner.
    //
    // The alternative was tried first and is worse: fitting the whole club puts a
    // thin diagonal line across a large empty square, which at 60 points on a home
    // screen is a white scratch. An icon is read at that size, so the head fills it
    // and the shaft is *deliberately* cropped — the grooves and the leading edge
    // are what say "wedge", and they are what survive the shrink.
    var rot = CGAffineTransform(rotationAngle: -13 * .pi / 180)
    let box = head.boundingBox.applying(rot)
    let target = CGRect(x: 150, y: 118, width: S - 340, height: S - 340)
    let scale = min(target.width / box.width, target.height / box.height)
    rot = rot
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(
            translationX: target.midX - (box.midX * scale),
            y: target.midY - (box.midY * scale)))

    func place(_ p: CGPath) -> CGPath { p.copy(using: &rot)! }

    ctx.setLineJoin(.round)
    for s in strokes {
        ctx.setStrokeColor(metal)
        ctx.setLineWidth(s.width * scale)
        ctx.setLineCap(s.cap)
        ctx.addPath(place(s.path))
        ctx.strokePath()
    }
    ctx.setFillColor(metal)
    ctx.addPath(place(shaft))
    ctx.addPath(place(head))
    ctx.fillPath()

    ctx.setStrokeColor(metalDark)
    ctx.setLineWidth(grooveWidth * scale)
    ctx.setLineCap(.butt)
    for g in grooves { ctx.addPath(place(g)) }
    ctx.strokePath()

    ctx.setStrokeColor(metalDark)
    ctx.setLineWidth(20 * scale)
    ctx.setLineCap(.round)
    ctx.addPath(place(sole))
    ctx.strokePath()

    ctx.setStrokeColor(grip)
    ctx.setLineWidth(gripStroke.width * scale)
    ctx.setLineCap(.round)
    ctx.addPath(place(gripStroke.path))
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
write(draw(.light),  to: dir + "/AppIcon.png")
write(draw(.dark),   to: dir + "/AppIcon-dark.png")
write(draw(.tinted), to: dir + "/AppIcon-tinted.png")
print("wrote 3 icons")
