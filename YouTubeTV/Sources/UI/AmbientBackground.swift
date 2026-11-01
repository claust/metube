import SwiftUI
import UIKit

/// The setting that turns the ambient background on and off — see `SettingsView`.
enum AmbientBackgroundSetting {
    static let key = "ambientBackgroundEnabled"
    static let defaultValue = true
}

/// Home's backdrop: in place of plain black, a few large soft blobs in the colours of the focused
/// card's channel, drifting slowly enough that they read as a mood rather than as motion.
///
/// The channel's picture rather than the video's thumbnail: a thumbnail is a busy frame whose
/// strongest colours are often skin and sky, while a channel's logo is a couple of colours chosen
/// to be recognised. The thumbnail stands in only for a channel whose picture isn't known.
///
/// Owns everything past "which video has focus": waiting for focus to settle, fetching the
/// picture, picking its colours and blending from one palette to the next. Black until the
/// first palette is known, and black for good when the setting is off.
struct AmbientHomeBackground: View {
    /// The card with focus, or `nil` when focus is somewhere else — the news, the menu, a row
    /// that doesn't report its cards. `nil` keeps whatever palette is showing rather than
    /// fading to black, so stepping up to the news doesn't flash the screen.
    let focusedVideo: VideoItem?
    /// False while something covers Home. The blobs stop drifting then, rather than redraw
    /// thirty times a second under a video nobody can see them behind.
    let isFrontmost: Bool

    @AppStorage(AmbientBackgroundSetting.key)
    private var isEnabled = AmbientBackgroundSetting.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var channelAvatars: ChannelAvatarStore
    @EnvironmentObject private var videoChannels: VideoChannelStore
    @State private var change: PaletteChange?
    /// True while `change` is still under way. Under Reduce Motion the blobs hold still, so once
    /// the colours have arrived there is nothing left to redraw and the timeline can stop.
    @State private var isBlending = false

    /// How long focus has to rest on a card before the background follows it. Holding a
    /// direction sweeps focus across a row, and a colour change per card passed over would be a
    /// strobe.
    private static let settleDelay = Duration.milliseconds(450)

    /// How much longer to give a channel's picture before settling for the thumbnail. A Home
    /// tile doesn't name its channel, and the card only looks it up once focus rests on it —
    /// arriving a moment later means one blend to the right colours, not two.
    private static let avatarGrace = Duration.milliseconds(1200)

    var body: some View {
        ZStack {
            Color.black
            if isEnabled, let change {
                AmbientBlobs(
                    change: change,
                    isPaused: !isFrontmost || (reduceMotion && !isBlending),
                    isDrifting: !reduceMotion
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: isEnabled)
        .ignoresSafeArea()
        // Keyed on the scene phase too, like `RemoteImage`'s load: a picture whose download died
        // with the app going to the background gets another try on the way back.
        .task(id: Follow(source: isEnabled ? source : nil, scenePhase: scenePhase)) {
            await follow(source)
        }
        .task(id: change) {
            guard change != nil else { return }
            isBlending = true
            try? await Task.sleep(for: .seconds(PaletteChange.duration))
            guard !Task.isCancelled else { return }
            isBlending = false
        }
    }

    /// What following focus is keyed on: change either and it starts over.
    private struct Follow: Equatable {
        let source: Source?
        let scenePhase: ScenePhase
    }

    /// The picture to take colours from, and whether it is the channel's own. Changes when the
    /// focused card's channel picture turns up, which restarts `follow` on the better picture.
    private var source: Source? {
        guard let video = focusedVideo else { return nil }
        if let avatar = channelAvatars.url(for: videoChannels.resolved(video)) {
            return Source(url: avatar, isChannelPicture: true)
        }
        return video.thumbnailURL.map { Source(url: $0, isChannelPicture: false) }
    }

    private struct Source: Equatable {
        let url: URL
        let isChannelPicture: Bool
    }

    @MainActor
    private func follow(_ source: Source?) async {
        guard isEnabled, let source else { return }
        let wait = source.isChannelPicture ? Self.settleDelay : Self.settleDelay + Self.avatarGrace
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled else { return }
        let url = source.url
        let found = await AmbientPaletteCache.shared.palette(for: url)
        guard !Task.isCancelled, let found else { return }
        let now = Date()
        // From whatever is on screen this instant — part way into the last blend, if focus moved
        // on before it finished — so a change of mind never jumps.
        let showing = change?.colours(at: now) ?? .black
        let target = AmbientColours(found)
        guard target != change?.to else { return }
        change = PaletteChange(from: showing, to: target, start: now)
    }
}

/// One blend from the colours that were showing to a new palette's.
///
/// Worked out per frame by the blobs' own timeline rather than handed to a SwiftUI animation. The
/// first version cross-faded two layers, and halfway through each was at half strength over
/// black: every focus change dipped the screen darker and back, which read as a flicker. Mixing
/// the colours themselves goes straight from one set to the other.
private struct PaletteChange: Equatable {
    let from: AmbientColours
    let to: AmbientColours
    let start: Date

    /// Long enough that the change is felt rather than seen.
    static let duration: TimeInterval = 2.5

    func colours(at date: Date) -> AmbientColours {
        let progress = min(max(date.timeIntervalSince(start) / Self.duration, 0), 1)
        // Smoothstep: eases in and out, so neither end of the blend has a visible edge.
        return from.mixed(with: to, by: progress * progress * (3 - 2 * progress))
    }
}

/// The background's three colours, in RGB so that two sets mix evenly — mixing hues would swing
/// round the colour wheel through colours neither palette has.
private struct AmbientColours: Equatable {
    let base: RGB
    let glow: RGB
    let accent: RGB

    static let black = AmbientColours(base: .black, glow: .black, accent: .black)

    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(_ hsb: AmbientPalette.HSB, brightness: Double? = nil) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            UIColor(
                hue: hsb.hue, saturation: hsb.saturation, brightness: brightness ?? hsb.brightness,
                alpha: 1
            )
            .getRed(&red, green: &green, blue: &blue, alpha: nil)
            self.init(red: red, green: green, blue: blue)
        }

        func mixed(with other: RGB, by amount: Double) -> RGB {
            RGB(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }

        var color: Color { Color(red: red, green: green, blue: blue) }
    }
}

extension AmbientColours {
    init(_ palette: AmbientPalette) {
        self.init(
            base: RGB(palette.background, brightness: 0.13),
            glow: RGB(palette.background, brightness: 0.30),
            accent: RGB(palette.accent))
    }

    func mixed(with other: AmbientColours, by amount: Double) -> AmbientColours {
        AmbientColours(
            base: base.mixed(with: other.base, by: amount),
            glow: glow.mixed(with: other.glow, by: amount),
            accent: accent.mixed(with: other.accent, by: amount))
    }
}

/// The drifting blobs themselves.
private struct AmbientBlobs: View {
    let change: PaletteChange
    let isPaused: Bool
    /// False under Reduce Motion: the blobs hold still, and only the colours still move.
    let isDrifting: Bool

    /// One soft circle: where it sits as a fraction of the screen, how far and how slowly it
    /// wanders from there, and how strongly it shows.
    private struct Blob {
        let colour: KeyPath<AmbientColours, AmbientColours.RGB>
        let diameter: CGFloat
        let origin: CGPoint
        let reach: CGSize
        let period: Double
        let phase: Double
        let opacity: Double
    }

    /// Periods of one to two minutes, and none a multiple of another, so the blobs never fall
    /// into step and the screen never visibly repeats.
    private static let blobs: [Blob] = [
        Blob(
            colour: \.accent, diameter: 1.0, origin: CGPoint(x: 0.12, y: 0.08),
            reach: CGSize(width: 0.12, height: 0.08), period: 71, phase: 0, opacity: 0.32),
        Blob(
            colour: \.glow, diameter: 1.25, origin: CGPoint(x: 0.92, y: 0.95),
            reach: CGSize(width: 0.10, height: 0.10), period: 97, phase: 1.7, opacity: 0.85),
        Blob(
            colour: \.accent, diameter: 0.7, origin: CGPoint(x: 0.55, y: 0.65),
            reach: CGSize(width: 0.14, height: 0.12), period: 59, phase: 3.1, opacity: 0.18),
        Blob(
            colour: \.glow, diameter: 0.8, origin: CGPoint(x: 0.35, y: 0.25),
            reach: CGSize(width: 0.09, height: 0.07), period: 113, phase: 4.4, opacity: 0.5),
    ]

    var body: some View {
        // Thirty frames a second is plenty for something this slow, and half the work of sixty.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { context in
            let colours = change.colours(at: context.date)
            let time = isDrifting ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geometry in
                ZStack {
                    colours.base.color
                    ForEach(Self.blobs.indices, id: \.self) { index in
                        blob(Self.blobs[index], in: colours, at: time, size: geometry.size)
                    }
                }
            }
        }
    }

    /// Radial gradients rather than blurred circles: the same soft edge, without asking the GPU
    /// for a full-screen blur every frame.
    private func blob(
        _ blob: Blob, in colours: AmbientColours, at time: Double, size: CGSize
    ) -> some View {
        let angle = time / blob.period * 2 * .pi + blob.phase
        let diameter = blob.diameter * size.width
        let colour = colours[keyPath: blob.colour].color
        return Circle()
            .fill(
                RadialGradient(
                    colors: [colour.opacity(blob.opacity), colour.opacity(0)],
                    center: .center, startRadius: 0, endRadius: diameter / 2)
            )
            .frame(width: diameter, height: diameter)
            .position(
                x: (blob.origin.x + blob.reach.width * sin(angle)) * size.width,
                y: (blob.origin.y + blob.reach.height * cos(angle * 0.8)) * size.height)
    }
}

/// The two colours the background is drawn from.
struct AmbientPalette: Hashable, Sendable {
    /// The thumbnail's dominant colour. Only its hue and saturation survive — the background
    /// sets the brightness itself, dark enough for white text on top.
    let background: HSB
    /// The thumbnail's most vivid colour that isn't the background's.
    let accent: HSB

    struct HSB: Hashable, Sendable {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }

    /// The palette of `image`, or `nil` for an image with no pixels to read.
    ///
    /// Shrinks the image to a few hundred pixels and sorts them into coarse colour buckets. The
    /// background is the biggest bucket, favouring colour over grey and passing over the black
    /// bars a 4:3 thumbnail carries; the accent is the bucket with the most vivid colour at a
    /// clearly different hue. A picture with no second colour gets a brighter shade of its
    /// first as its accent.
    static func extract(from image: UIImage) -> AmbientPalette? {
        guard let pixels = image.cgImage.flatMap(samplePixels) else { return nil }

        var buckets: [Int: Bucket] = [:]
        for pixel in pixels {
            let key = Int(pixel.red * 7.99) << 6 | Int(pixel.green * 7.99) << 3 | Int(pixel.blue * 7.99)
            buckets[key, default: Bucket()].add(pixel)
        }
        let colours = buckets.values.map { $0.mean }

        guard
            let background = colours.max(by: { $0.backgroundScore < $1.backgroundScore })
        else { return nil }

        let accent =
            colours
            .filter { $0.hsb.saturation > 0.25 && hueDistance($0.hsb.hue, background.hsb.hue) > 0.08 }
            .max(by: { $0.accentScore < $1.accentScore })

        let ground = background.hsb
        let accentHSB =
            accent.map {
                HSB(
                    hue: $0.hsb.hue, saturation: min($0.hsb.saturation, 0.85),
                    brightness: min(max($0.hsb.brightness, 0.6), 0.9))
            }
            // A grey picture's hue means nothing (UIKit reports 0, red), so only a coloured
            // background gets its saturation lifted; a grey one gets a lighter grey.
            ?? HSB(
                hue: ground.hue,
                saturation: ground.saturation < 0.1 ? ground.saturation : min(ground.saturation + 0.2, 0.8),
                brightness: 0.7)

        return AmbientPalette(
            background: HSB(
                hue: ground.hue, saturation: min(ground.saturation, 0.75),
                brightness: ground.brightness),
            accent: accentHSB)
    }

    private static func hueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }

    /// The image drawn down to 32×18 — a 16:9 thumbnail's shape — as RGB in 0...1.
    private static func samplePixels(_ image: CGImage) -> [Pixel]? {
        let width = 32
        let height = 18
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map {
            Pixel(
                red: Double(bytes[$0]) / 255, green: Double(bytes[$0 + 1]) / 255,
                blue: Double(bytes[$0 + 2]) / 255)
        }
    }

    private struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The pixels that fell into one colour bucket.
    private struct Bucket {
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        mutating func add(_ pixel: Pixel) {
            count += 1
            red += pixel.red
            green += pixel.green
            blue += pixel.blue
        }

        var mean: Swatch {
            let total = Double(count)
            return Swatch(
                count: count,
                hsb: UIColor(red: red / total, green: green / total, blue: blue / total, alpha: 1).hsb)
        }
    }

    /// A bucket's average colour and how many pixels it stands for.
    private struct Swatch {
        let count: Int
        let hsb: HSB

        /// Big buckets win, coloured ones over grey ones, and near-black — letterboxing, a dark
        /// frame — hardly counts at all.
        var backgroundScore: Double {
            let darkPenalty = hsb.brightness < 0.08 ? 0.1 : 1
            return Double(count) * (0.3 + 0.7 * hsb.saturation) * darkPenalty
        }

        /// Vivid and bright beats big: an accent can be a small patch of the image.
        var accentScore: Double {
            Double(count).squareRoot() * hsb.saturation * hsb.saturation * hsb.brightness
        }
    }
}

extension UIColor {
    fileprivate var hsb: AmbientPalette.HSB {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return AmbientPalette.HSB(hue: hue, saturation: saturation, brightness: brightness)
    }
}

/// Palettes already worked out, by picture. Scrolling back along a row asks again for cards it
/// has passed, and the answer doesn't change.
actor AmbientPaletteCache {
    static let shared = AmbientPaletteCache()

    private var palettes: [URL: AmbientPalette] = [:]

    func palette(for url: URL) async -> AmbientPalette? {
        if let known = palettes[url] { return known }
        // The card is showing this picture, so this is almost always a memory hit.
        guard let image = try? await ImageCache.shared.image(for: url),
            let palette = AmbientPalette.extract(from: image)
        else { return nil }
        palettes[url] = palette
        return palette
    }
}
