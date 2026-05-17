import SwiftUI
import GoogleSignIn

// MARK: - GismoEmotion (internal so ViewModel can reference via GismoEmotion.from)

enum GismoEmotion: CaseIterable, Identifiable {
    case veryHappy, happy, neutral, sad, angry, thoughtful, listening, surprised, sleeping

    var id: Self { self }

    static func from(_ name: GismoEmotionName) -> GismoEmotion {
        switch name {
        case .neutral:    return .neutral
        case .happy:      return .happy
        case .veryHappy:  return .veryHappy
        case .sad:        return .sad
        case .angry:      return .angry
        case .thoughtful: return .thoughtful
        case .listening:  return .listening
        case .surprised:  return .surprised
        case .sleeping:   return .sleeping
        }
    }

    var title: String {
        switch self {
        case .veryHappy:  "Çok mutlu"
        case .happy:      "Mutlu"
        case .neutral:    "Normal"
        case .sad:        "Üzgün"
        case .angry:      "Kızgın"
        case .thoughtful: "Düşünceli"
        case .listening:  "Dinliyor"
        case .surprised:  "Şaşırmış"
        case .sleeping:   "Uyuyor"
        }
    }

    var primary: Color {
        switch self {
        case .veryHappy:  Color(hex: "FFE66D")
        case .happy:      Color(hex: "00D4AA")
        case .neutral:    Color(hex: "72DDF7")
        case .sad:        Color(hex: "5B8FF9")
        case .angry:      Color(hex: "FF4560")
        case .thoughtful: Color(hex: "B794F4")
        case .listening:  Color(hex: "7AFBFF")
        case .surprised:  Color(hex: "FFB800")
        case .sleeping:   Color(hex: "3A4A6B")
        }
    }

    var secondary: Color {
        switch self {
        case .veryHappy:  Color(hex: "FF9F1C")
        case .happy:      Color(hex: "55E6C1")
        case .neutral:    Color(hex: "A7F3FF")
        case .sad:        Color(hex: "9EC5FF")
        case .angry:      Color(hex: "FF7A59")
        case .thoughtful: Color(hex: "7B61FF")
        case .listening:  Color(hex: "00D4AA")
        case .surprised:  Color(hex: "FFD166")
        case .sleeping:   Color(hex: "1A2340")
        }
    }

    var background: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "05050A"), primary.opacity(0.22), Color(hex: "080812")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var eyeWidthRatio: CGFloat {
        switch self {
        case .surprised: 0.30
        case .angry:     0.36
        case .sad:       0.37
        case .listening: 0.34
        default:         0.38
        }
    }

    var eyeHeightRatio: CGFloat {
        switch self {
        case .veryHappy:  0.14
        case .happy:      0.16
        case .neutral:    0.22
        case .sad:        0.18
        case .angry:      0.18
        case .thoughtful: 0.20
        case .listening:  0.18
        case .surprised:  0.32
        case .sleeping:   0.04  // neredeyse kapalı
        }
    }

    var eyeSpacingRatio: CGFloat {
        switch self {
        case .surprised: 0.13
        case .angry:     0.10
        case .listening: 0.16
        case .sleeping:  0.12
        default:         0.12
        }
    }

    var eyeYOffsetRatio: CGFloat {
        switch self {
        case .sad:        0.04
        case .thoughtful: 0.02
        case .listening:  -0.01
        case .surprised:  -0.02
        default:          0
        }
    }

    var mouthYOffsetRatio: CGFloat {
        switch self {
        case .surprised: 0.02
        case .sad:       0.04
        default:         0
        }
    }

    var pulseDuration: Double {
        switch self {
        case .veryHappy:  0.9
        case .happy:      1.15
        case .angry:      0.55
        case .listening:  1.0
        case .surprised:  0.75
        case .sleeping:   3.5  // çok yavaş
        default:          1.8
        }
    }
}

// MARK: - GismoFaceView

struct GismoFaceView: View {
    @StateObject private var vm: GismoFaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false
    @State private var blink = false
    @State private var floatPhase = false
    @State private var blinkTask: Task<Void, Never>? = nil
    @Environment(\.scenePhase) var scenePhase

    init(robot: Robot) {
        _vm = StateObject(wrappedValue: GismoFaceViewModel(robot: robot))
    }

    private var emotion: GismoEmotion { GismoEmotion.from(vm.currentEmotion) }

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = min(geometry.size.width * 0.92, geometry.size.height * 1.65)
            let eyeWidth   = canvasSize * emotion.eyeWidthRatio
            let eyeHeight  = canvasSize * emotion.eyeHeightRatio

            ZStack {
                emotion.background.ignoresSafeArea()

                RadialGradient(
                    colors: [emotion.primary.opacity(0.34), .clear],
                    center: .center,
                    startRadius: canvasSize * 0.08,
                    endRadius: canvasSize * 0.8
                )
                .scaleEffect(pulse ? 1.08 : 0.94)
                .animation(.easeInOut(duration: emotion.pulseDuration).repeatForever(autoreverses: true), value: pulse)
                .ignoresSafeArea()

                FaceEffectLayer(emotion: emotion, canvasSize: canvasSize, floatPhase: floatPhase)

                VStack(spacing: canvasSize * 0.04) {
                    Spacer(minLength: canvasSize * 0.02)
                    HStack(spacing: canvasSize * emotion.eyeSpacingRatio) {
                        // Sol göz → kamera lens modunda lens'e dönüşür
                        if vm.camera.lensMode {
                            CameraLensEye(size: eyeWidth, color: emotion.primary)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            GismoEye(emotion: emotion, side: .left, width: eyeWidth, height: eyeHeight, isBlinking: blink, floatPhase: floatPhase)
                                .transition(.scale.combined(with: .opacity))
                        }
                        GismoEye(emotion: emotion, side: .right, width: eyeWidth, height: eyeHeight, isBlinking: blink, floatPhase: floatPhase)
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.65), value: vm.camera.lensMode)
                    .offset(y: canvasSize * emotion.eyeYOffsetRatio)
                    GismoMouth(emotion: emotion, size: canvasSize)
                        .offset(y: canvasSize * emotion.mouthYOffsetRatio)
                    Spacer(minLength: canvasSize * 0.02)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Shutter flaşı
                if vm.camera.shutterFlash {
                    Color.white
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(9)
                }

                // Overlay
                VStack {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.black.opacity(0.28)))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        
                        Button {
                            withAnimation { vm.isTrackingEnabled.toggle() }
                        } label: {
                            Image(systemName: vm.isTrackingEnabled ? "eye.fill" : "eye.slash.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(vm.isTrackingEnabled ? .white : .white.opacity(0.3))
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.black.opacity(0.28)))
                        }
                        .buttonStyle(ScaleButtonStyle())
                        
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(emotion.title)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            Text(vm.robot.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.58))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer()

                    // AI yanıt balonu
                    if vm.showResponse && !vm.aiResponse.isEmpty {
                        Text(vm.aiResponse)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.black.opacity(0.52))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(emotion.primary.opacity(0.4), lineWidth: 1))
                            )
                            .padding(.horizontal, 24)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Canlı transkript
                    if !vm.liveTranscript.isEmpty {
                        Text(vm.liveTranscript)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.horizontal, 28)
                            .transition(.opacity)
                    }

                    // Durum göstergesi
                    HStack(spacing: 6) {
                        if vm.isThinking {
                            ProgressView().tint(.white.opacity(0.7)).scaleEffect(0.7)
                            Text("Düşünüyor...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                        } else if vm.permissionDenied {
                            Image(systemName: "mic.slash").font(.system(size: 12)).foregroundColor(.red.opacity(0.7))
                            Text("Mikrofon izni gerekli")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red.opacity(0.7))
                        } else {
                            MicPulseIndicator(isActive: vm.isListening, color: emotion.primary)
                            Text(vm.isListening ? "Dinliyor" : "Bağlanıyor...")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .padding(.bottom, 18)
                }

                // Fotoğraf önizleme overlay — emotion temasıyla entegre
                if vm.camera.showPreview, let photo = vm.camera.capturedImage {
                    ZStack {
                        // Arka plan: emotion rengi + blur
                        emotion.background
                            .ignoresSafeArea()
                            .overlay(
                                RadialGradient(
                                    colors: [emotion.primary.opacity(0.4), emotion.secondary.opacity(0.15)],
                                    center: .center, startRadius: 40, endRadius: 280
                                )
                            )

                        VStack(spacing: 16) {
                            // Polaroid çerçeve
                            VStack(spacing: 0) {
                                Image(uiImage: photo)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 240, height: 200)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 240, height: 44)
                                    .overlay(
                                        Text("Gismo ile selfie 📸")
                                            .font(.system(size: 13, weight: .medium, design: .rounded))
                                            .foregroundColor(Color(hex: "333333"))
                                    )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
                            .rotationEffect(.degrees(-2))

                            // Badge
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(emotion.primary)
                                Text("Galeriye kaydedildi")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(10)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            if vm.currentEmotion == .sleeping {
                vm.wakeUp()
            }
        }
        .onAppear {
            AppOrientation.lock([.landscapeLeft, .landscapeRight])
            pulse = true
            floatPhase = true
            blinkTask = scheduleBlink()
            vm.onAppear()
        }
        .onDisappear {
            AppOrientation.lock(.portrait)
            blinkTask?.cancel()
            vm.onDisappear()
        }
        .animation(.easeInOut(duration: 0.3), value: vm.showResponse)
        .animation(.easeInOut(duration: 0.2), value: vm.liveTranscript)
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                print("[App] Foreground - Gismo resuming...")
                vm.onAppear()
            } else if newPhase == .background {
                print("[App] Background - Gismo sleeping...")
                vm.onDisappear()
            }
        }
    }

    @discardableResult
    private func scheduleBlink() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 0.6...1.6)))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.06)) { blink = true }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.09)) { blink = false }
            }
        }
    }
}

// MARK: - Mic Pulse Indicator

private struct MicPulseIndicator: View {
    let isActive: Bool
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse && isActive ? 1.5 : 1.0)
                .opacity(pulse && isActive ? 0 : 0.6)
                .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: pulse)
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isActive ? color : .white.opacity(0.3))
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Eye Side

private enum EyeSide { case left, right }

// MARK: - GismoEye

private struct GismoEye: View {
    let emotion: GismoEmotion
    let side: EyeSide
    let width: CGFloat
    let height: CGFloat
    let isBlinking: Bool
    let floatPhase: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.48, style: .continuous)
                .fill(LinearGradient(colors: [emotion.primary, emotion.secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width, height: isBlinking ? max(8, height * 0.08) : height)
                .shadow(color: emotion.primary.opacity(0.8), radius: 26, x: 0, y: 0)
                .overlay(alignment: .topLeading) {
                    if !isBlinking && emotion != .angry && emotion != .sad {
                        Capsule()
                            .fill(Color.white.opacity(0.65))
                            .frame(width: width * 0.22, height: max(5, height * 0.12))
                            .offset(x: width * 0.18, y: height * 0.17)
                    }
                }
                .rotationEffect(rotation)

            if emotion == .surprised && !isBlinking {
                Circle()
                    .fill(Color.white.opacity(0.86))
                    .frame(width: width * 0.16, height: width * 0.16)
                    .offset(x: side == .left ? width * 0.15 : -width * 0.15, y: -height * 0.12)
            }
        }
        .offset(y: floatPhase ? floatingOffset : -floatingOffset)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: floatPhase)
    }

    private var rotation: Angle {
        switch emotion {
        case .sad:        side == .left ? .degrees(8)   : .degrees(-8)
        case .angry:      side == .left ? .degrees(-11) : .degrees(11)
        case .thoughtful: side == .left ? .degrees(-4)  : .degrees(5)
        case .listening:  side == .left ? .degrees(4)   : .degrees(-4)
        default:          .degrees(0)
        }
    }

    private var floatingOffset: CGFloat {
        switch emotion {
        case .veryHappy: -8
        case .happy:     -5
        case .surprised: -4
        case .listening: -3
        case .sad:        3
        default:          2
        }
    }
}

// MARK: - GismoMouth

private struct GismoMouth: View {
    let emotion: GismoEmotion
    let size: CGFloat

    var body: some View {
        Group {
            switch emotion {
            case .veryHappy:
                SmileShape(depth: size * 0.12)
                    .stroke(emotion.primary, style: StrokeStyle(lineWidth: max(9, size * 0.022), lineCap: .round))
                    .frame(width: size * 0.30, height: size * 0.16)
            case .happy:
                SmileShape(depth: size * 0.085)
                    .stroke(emotion.primary, style: StrokeStyle(lineWidth: max(8, size * 0.019), lineCap: .round))
                    .frame(width: size * 0.25, height: size * 0.13)
            case .neutral:
                Capsule().fill(emotion.primary.opacity(0.72))
                    .frame(width: size * 0.22, height: max(7, size * 0.016))
            case .sad:
                SmileShape(depth: -size * 0.08)
                    .stroke(emotion.primary, style: StrokeStyle(lineWidth: max(8, size * 0.019), lineCap: .round))
                    .frame(width: size * 0.24, height: size * 0.12)
            case .angry:
                Capsule().fill(emotion.primary)
                    .frame(width: size * 0.20, height: max(8, size * 0.018))
                    .rotationEffect(.degrees(-4))
            case .thoughtful:
                Capsule().fill(emotion.primary.opacity(0.75))
                    .frame(width: size * 0.13, height: max(8, size * 0.018))
                    .offset(x: size * 0.05)
            case .listening:
                HStack(spacing: size * 0.018) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(emotion.primary.opacity(0.86))
                            .frame(width: max(7, size * 0.016), height: size * CGFloat(0.030 + Double(index) * 0.018))
                    }
                }
            case .surprised:
                Circle()
                    .stroke(emotion.primary, lineWidth: max(8, size * 0.020))
                    .frame(width: size * 0.12, height: size * 0.12)
                    .shadow(color: emotion.primary.opacity(0.65), radius: 16, x: 0, y: 0)
            case .sleeping:
                Capsule()
                    .fill(emotion.primary.opacity(0.5))
                    .frame(width: size * 0.10, height: max(6, size * 0.013))
                    .offset(y: size * 0.01)
            }
        }
        .shadow(color: emotion.primary.opacity(0.55), radius: 12, x: 0, y: 0)
    }
}

// MARK: - SmileShape

private struct SmileShape: Shape {
    let depth: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + depth))
        return path
    }
}

// MARK: - FaceEffectLayer

private struct FaceEffectLayer: View {
    let emotion: GismoEmotion
    let canvasSize: CGFloat
    let floatPhase: Bool

    var body: some View {
        ZStack {
            switch emotion {
            case .veryHappy:  sparkleField(count: 12)
            case .happy:      sparkleField(count: 7)
            case .neutral:    orbitDots
            case .sad:        tearDrops
            case .angry:      angerMarks
            case .thoughtful: thoughtBubbles
            case .listening:  listeningWaves
            case .surprised:  surpriseLines
            case .sleeping:   sleepingZzzs
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .drawingGroup()          // GPU'da rasterize et — CPU yükü düşer
        .allowsHitTesting(false)
    }

    private func sparkleField(count: Int) -> some View {
        ForEach(0..<count, id: \.self) { index in
            Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "star.fill")
                .font(.system(size: canvasSize * CGFloat(0.026 + Double(index % 3) * 0.006), weight: .bold))
                .foregroundColor(index.isMultiple(of: 2) ? emotion.primary : emotion.secondary)
                .opacity(0.78)
                .rotationEffect(.degrees(floatPhase ? Double(index * 28 + 22) : Double(index * 28 - 22)))
                .scaleEffect(floatPhase ? 1.28 : 0.72)
                .offset(
                    x: cos(Double(index) * 1.7) * canvasSize * (emotion == .veryHappy ? 0.50 : 0.42),
                    y: sin(Double(index) * 1.2) * canvasSize * (emotion == .veryHappy ? 0.32 : 0.26) + (floatPhase ? -24 : 18)
                )
                .animation(.easeInOut(duration: 0.72 + Double(index % 4) * 0.12).repeatForever(autoreverses: true), value: floatPhase)
        }
    }

    private var orbitDots: some View {
        ForEach(0..<8, id: \.self) { index in
            Circle()
                .fill(emotion.primary.opacity(0.32))
                .frame(width: canvasSize * 0.018, height: canvasSize * 0.018)
                .offset(x: cos(Double(index) * .pi / 4) * canvasSize * 0.36,
                        y: sin(Double(index) * .pi / 4) * canvasSize * 0.22)
        }
    }

    private var tearDrops: some View {
        TimelineView(.periodic(from: .now, by: 1.0/30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let duration = 0.95 + Double(index % 3) * 0.18
                    let delay = Double(index) * 0.17
                    let progress = ((now + delay).truncatingRemainder(dividingBy: duration)) / duration
                    let easedProgress = pow(progress, 1.28)
                    let xSide: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                    let xSpread = canvasSize * (0.18 + CGFloat(index % 4) * 0.038)
                    Image(systemName: "drop.fill")
                        .font(.system(size: canvasSize * CGFloat(0.038 + Double(index % 2) * 0.012), weight: .bold))
                        .foregroundColor(Color(hex: "8EDBFF")).opacity(0.82)
                        .offset(x: xSide * xSpread + sin(now * 3.0 + Double(index)) * canvasSize * 0.010,
                                y: -canvasSize * 0.04 + canvasSize * 0.46 * CGFloat(easedProgress))
                        .opacity(1.0 - max(0, CGFloat(progress) - 0.72) / 0.28)
                }
            }
        }
    }

    private var angerMarks: some View {
        TimelineView(.periodic(from: .now, by: 1.0/30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let flash = sin(now * 18.0) > 0.18
            let hardFlash = sin(now * 37.0) > 0.72
            let shakeX = sin(now * 48.0) * canvasSize * 0.012
            ZStack {
                ForEach(0..<9, id: \.self) { index in
                    let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                    let phase = now * (8.0 + Double(index % 3) * 2.3) + Double(index)
                    let isLit = sin(phase) > 0.25
                    Image(systemName: "bolt.fill")
                        .font(.system(size: canvasSize * CGFloat(0.052 + Double(index % 3) * 0.018), weight: .black))
                        .foregroundStyle(LinearGradient(colors: [hardFlash ? .white : emotion.secondary, emotion.primary], startPoint: .top, endPoint: .bottom))
                        .shadow(color: emotion.primary.opacity(isLit ? 0.95 : 0.25), radius: isLit ? 20 : 5)
                        .opacity(isLit ? 1.0 : 0.18)
                        .scaleEffect(isLit ? 1.25 : 0.68)
                        .offset(x: side * canvasSize * (0.18 + CGFloat(index % 4) * 0.085) + shakeX,
                                y: -canvasSize * (0.18 + CGFloat(index % 3) * 0.08))
                }
            }
            .offset(x: shakeX)
        }
    }

    private var thoughtBubbles: some View {
        VStack(spacing: canvasSize * 0.018) {
            Text("...").font(.system(size: canvasSize * 0.09, weight: .black, design: .rounded)).foregroundColor(emotion.primary)
            HStack(spacing: canvasSize * 0.018) {
                Circle().fill(emotion.primary.opacity(0.7)).frame(width: canvasSize * 0.026, height: canvasSize * 0.026)
                Circle().fill(emotion.primary.opacity(0.45)).frame(width: canvasSize * 0.018, height: canvasSize * 0.018)
            }
        }
        .offset(x: canvasSize * 0.28, y: -canvasSize * 0.22 + (floatPhase ? -8 : 8))
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: floatPhase)
    }

    private var listeningWaves: some View {
        TimelineView(.periodic(from: .now, by: 1.0/30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let progress = CGFloat((now + Double(index) * 0.22).truncatingRemainder(dividingBy: 1.1) / 1.1)
                    let scale = 0.76 + progress * 0.52
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(emotion.primary.opacity(0.66 * (1.0 - progress)), lineWidth: max(2, canvasSize * 0.005))
                        .frame(width: canvasSize * 0.58, height: canvasSize * 0.25)
                        .scaleEffect(x: scale, y: scale * 0.92)
                }
                HStack(spacing: canvasSize * 0.62) {
                    listeningBars(side: -1, now: now)
                    listeningBars(side: 1, now: now)
                }
            }
        }
    }

    private func listeningBars(side: CGFloat, now: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: canvasSize * 0.010) {
            ForEach(0..<5, id: \.self) { index in
                let beat = CGFloat((sin(now * (4.4 + Double(index) * 0.7) + Double(index) * 1.3) + 1) / 2)
                Capsule()
                    .fill(LinearGradient(colors: [emotion.primary, emotion.secondary], startPoint: .top, endPoint: .bottom))
                    .frame(width: canvasSize * 0.013, height: canvasSize * (0.035 + beat * 0.115))
                    .shadow(color: emotion.primary.opacity(0.58), radius: 9)
            }
        }
        .scaleEffect(x: side, y: 1)
    }

    private var surpriseLines: some View {
        ForEach(0..<10, id: \.self) { index in
            Capsule()
                .fill(emotion.primary.opacity(0.70))
                .frame(width: canvasSize * 0.01, height: canvasSize * 0.07)
                .offset(y: -canvasSize * 0.34)
                .rotationEffect(.degrees(Double(index) * 36))
                .offset(x: cos(Double(index) * .pi / 5) * canvasSize * 0.34,
                        y: sin(Double(index) * .pi / 5) * canvasSize * 0.20)
                .scaleEffect(floatPhase ? 1.28 : 0.72)
                .opacity(floatPhase ? 0.95 : 0.45)
                .animation(.easeInOut(duration: 0.46).repeatForever(autoreverses: true), value: floatPhase)
        }
    }

    private var sleepingZzzs: some View {
        TimelineView(.periodic(from: .now, by: 1.0/30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let delay = Double(index) * 0.9
                    let duration = 2.8
                    let progress = CGFloat(((now + delay).truncatingRemainder(dividingBy: duration)) / duration)
                    let size = canvasSize * CGFloat(0.055 + Double(index) * 0.018)
                    Text("Z")
                        .font(.system(size: size, weight: .black, design: .rounded))
                        .foregroundColor(Color(hex: "7A9FD4").opacity(Double(0.85 - progress * 0.6)))
                        .shadow(color: Color(hex: "3A6EA8").opacity(0.5), radius: 8)
                        .offset(
                            x: canvasSize * 0.22 + CGFloat(index) * canvasSize * 0.06 + sin(now * 0.8 + Double(index)) * canvasSize * 0.03,
                            y: -canvasSize * 0.08 - progress * canvasSize * 0.35
                        )
                        .scaleEffect(0.7 + Double(progress) * 0.5)
                }
            }
        }
    }
}

// MARK: - CameraLensEye

struct CameraLensEye: View {
    let size: CGFloat
    let color: Color
    @State private var rotating = false
    @State private var iris: CGFloat = 0.55

    var body: some View {
        ZStack {
            // Dış çerçeve
            Circle()
                .fill(Color.black)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(color, lineWidth: 2.5))
                .shadow(color: color.opacity(0.8), radius: 12)

            // Diyafram bıçakları (6 adet)
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 0.12, height: size * 0.42)
                    .offset(y: -size * 0.18)
                    .rotationEffect(.degrees(Double(i) * 60 + (rotating ? 30 : 0)))
                    .animation(.easeInOut(duration: 0.5).delay(Double(i) * 0.05), value: rotating)
            }

            // İç iris halkalar
            ForEach([0.68, 0.48, 0.28], id: \.self) { ratio in
                Circle()
                    .stroke(color.opacity(ratio == 0.68 ? 0.6 : ratio == 0.48 ? 0.4 : 0.25), lineWidth: 1.5)
                    .frame(width: size * ratio, height: size * ratio)
            }

            // Merkez — parlak nokta
            Circle()
                .fill(
                    RadialGradient(colors: [color, color.opacity(0.3)],
                                   center: .center, startRadius: 0, endRadius: size * 0.12)
                )
                .frame(width: size * (iris * 0.42), height: size * (iris * 0.42))

            // Lens parıltısı
            Ellipse()
                .fill(Color.white.opacity(0.55))
                .frame(width: size * 0.12, height: size * 0.07)
                .offset(x: -size * 0.09, y: -size * 0.11)
                .blur(radius: 2)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4)) { rotating = true }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { iris = 0.85 }
        }
    }
}

// MARK: - Preview

#Preview {
    GismoFaceView(robot: Robot(name: "Gismo", ipAddress: "192.168.4.1", isOnline: true))
}

// MARK: - Integrations View

struct IntegrationsView: View {
    @StateObject private var authService = GoogleAuthService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showGoogleInfo = false
    
    @AppStorage("isSmsActive") private var isSmsActive: Bool = false
    @State private var showSMSInfo = false
    @State private var showSMSLogin = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Premium Gradient Background
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.1, green: 0.1, blue: 0.15)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
                
                VStack(spacing: 32) {
                    
                    // Başlık Bilgisi
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dijital Asistan")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Gismo'yu yetkilendirerek senin adına e-posta atmasını, fotoğraf göndermesini ve Google Drive'ına erişmesini sağlayabilirsin.")
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    
                    // Google Card
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 16) {
                            // Modern Icon
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                                
                                Image("GoogleIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 32, height: 32)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Google Servisleri")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                if authService.isConnected, let email = authService.currentUser?.profile?.email {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: .green.opacity(0.8), radius: 4)
                                        Text(email)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(.green.opacity(0.9))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("Bağlantı Bekleniyor")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        
                        HStack(spacing: 12) {
                            Spacer()
                            
                            Button {
                                showGoogleInfo = true
                            } label: {
                                Text("Detaylar")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.05))
                                    .foregroundColor(.white.opacity(0.8))
                                    .cornerRadius(20)
                            }
                            
                            if authService.isConnected {
                                Button {
                                    withAnimation { authService.signOut() }
                                } label: {
                                    Text("Kaldır")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                }
                            } else {
                                Button {
                                    signIn()
                                } label: {
                                    Text("Bağla")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 10)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                        .shadow(color: .blue.opacity(0.3), radius: 5, x: 0, y: 3)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(authService.isConnected ? Color.green.opacity(0.04) : Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(authService.isConnected ? Color.green.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .shadow(color: authService.isConnected ? Color.green.opacity(0.1) : .clear, radius: 15, x: 0, y: 8)
                    .padding(.horizontal, 24)
                    
                    // SMS Card
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 16) {
                            // SMS Icon
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                                
                                Image("NetgsmIcon")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SMS Gönderimi")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                
                                if isSmsActive {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: .green.opacity(0.8), radius: 4)
                                        Text("Netgsm Altyapısı Aktif")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundColor(.green.opacity(0.9))
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("Pasif Durumda")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        
                        HStack(spacing: 12) {
                            Spacer()
                            
                            Button {
                                showSMSInfo = true
                            } label: {
                                Text("Detaylar")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.05))
                                    .foregroundColor(.white.opacity(0.8))
                                    .cornerRadius(20)
                            }
                            
                            if isSmsActive {
                                Button {
                                    withAnimation { isSmsActive = false }
                                } label: {
                                    Text("Kapat")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                }
                            } else {
                                Button {
                                    showSMSLogin = true
                                } label: {
                                    Text("Aç")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 10)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                        .shadow(color: .orange.opacity(0.3), radius: 5, x: 0, y: 3)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(isSmsActive ? Color.green.opacity(0.04) : Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(isSmsActive ? Color.green.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .shadow(color: isSmsActive ? Color.green.opacity(0.1) : .clear, radius: 15, x: 0, y: 8)
                    .padding(.horizontal, 24)
                    
                    Spacer()
                }
            }
            .navigationTitle("Entegrasyonlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 24))
                    }
                }
            }
            .sheet(isPresented: $showGoogleInfo) {
                GoogleInfoView()
            }
            .sheet(isPresented: $showSMSInfo) {
                SMSInfoView()
            }
            .sheet(isPresented: $showSMSLogin) {
                SMSLoginView()
            }
            // URL scheme yakalama (Eğer custom URL kullanılıyorsa)
            .onOpenURL { url in
                GIDSignIn.sharedInstance.handle(url)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func signIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        
        authService.signIn(presenting: rootVC)
    }
}

// MARK: - Google Info View

struct GoogleInfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    
                    // Hero Banner & Header
                    ZStack(alignment: .bottomLeading) {
                        Image("GoogleBanner")
                            .resizable()
                            .scaledToFill()
                            .frame(height: 220)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [Color.black.opacity(0.1), Color(red: 0.1, green: 0.1, blue: 0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        HStack(spacing: 16) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 56, height: 56)
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                .overlay(
                                    Image("GoogleIcon")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 32, height: 32)
                                )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Entegrasyon")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("Google Servisleri")
                                    .font(.system(size: 26, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    
                    // Content
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Bu entegrasyon sayesinde Gismo artık sadece bir robot değil, aynı zamanda kişisel dijital asistanın haline geliyor. Google hesabını bağladığında Gismo aşağıdaki işlemleri senin adına güvenle yapabilir:")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.bottom, 10)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        InfoRow(icon: "envelope.fill", color: .blue, title: "E-Posta Yönetimi", desc: "Belirttiğin adreslere e-posta gönderebilir veya gelen kutundaki son mailleri okuyup özetleyebilir.")
                        InfoRow(icon: "camera.fill", color: .purple, title: "Fotoğraf & Mail", desc: "Seni görüp fotoğrafını çekebilir ve anında dilediğin kişiye mail olarak eklentiyle yollayabilir.")
                        InfoRow(icon: "externaldrive.fill", color: .green, title: "Google Drive Dosya Yükleme", desc: "Çektiği fotoğrafları güvenle doğrudan kendi Google Drive'ına kaydedebilir.")
                        InfoRow(icon: "doc.text.magnifyingglass", color: .orange, title: "Drive'da Arama ve Okuma", desc: "Google Drive'ındaki metin veya doküman dosyalarını isminden bulup içeriğini saniyeler içinde okuyup özetleyebilir.")
                    }
                    
                    Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.blue)
                        Text("Örnek Senaryolar")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        ScenarioBubble(text: "\"Hey Gismo, fotoğrafımı çek ve Drive'ıma yükle.\"")
                        ScenarioBubble(text: "\"Bugün kimden mail gelmiş, bana kısaca özetler misin?\"")
                        ScenarioBubble(text: "\"Beni çekip patrona 'Toplantıya hazırım' diye mail at.\"")
                        ScenarioBubble(text: "\"Drive'ımdaki '2026 Hesaplar' adlı dosyayı bulup bana anlatır mısın?\"")
                    }
                }
                .padding(20)
                } // End of VStack(spacing: 0)
            } // End of ScrollView
            .background(Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea())
            .navigationTitle("Özellikler & Komutlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                        .foregroundColor(.blue)
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct InfoRow: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

struct ScenarioBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "quote.opening")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(.blue.opacity(0.6))
                .padding(.top, 2)
            
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .lineSpacing(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - SMS Info View

struct SMSInfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    
                    // Hero Banner & Header
                    ZStack(alignment: .bottomLeading) {
                        Image("NetgsmBanner")
                            .resizable()
                            .scaledToFill()
                            .frame(height: 220)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [Color.black.opacity(0.1), Color(red: 0.1, green: 0.1, blue: 0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        HStack(spacing: 16) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 56, height: 56)
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                .overlay(
                                    Image("NetgsmIcon")
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 36, height: 36)
                                        .clipShape(Circle())
                                )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Entegrasyon")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("SMS Gönderimi")
                                    .font(.system(size: 26, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    
                    // Content
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Gismo, Netgsm API altyapısını kullanarak arka planda hızlı ve güvenli SMS gönderimi yapabilir. Bu entegrasyon sayesinde doğrudan telefonundan veya ekrandan onay vermene gerek kalmadan Gismo senin yerine mesaj atar.")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.8))
                            .lineSpacing(4)
                            .padding(.bottom, 10)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            InfoRow(icon: "paperplane.fill", color: .orange, title: "Hızlı İletişim", desc: "Sevdiklerine gecikeceğini veya acil durumları saniyeler içinde haber verebilir.")
                            InfoRow(icon: "briefcase.fill", color: .blue, title: "İş Bilgilendirmesi", desc: "Toplantı saatlerini, güncellemeleri veya müşteri mesajlarını anında atabilir.")
                        }
                        
                        Divider().background(Color.white.opacity(0.2)).padding(.vertical, 8)
                        
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.orange)
                            Text("Örnek Senaryolar")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            ScenarioBubble(text: "\"Hey Gismo, anneme '10 dakika gecikeceğim' diye SMS at.\"")
                            ScenarioBubble(text: "\"Hakan'a mesaj at: Toplantı saat 14:00'e alındı.\"")
                            ScenarioBubble(text: "\"Eşime SMS at: Eve gelirken ekmek alacağım.\"")
                        }
                    }
                    .padding(20)
                } // End of VStack(spacing: 0)
            } // End of ScrollView
            .background(Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea())
            .navigationTitle("Özellikler & Komutlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Kapat") { dismiss() }
                        .foregroundColor(.orange)
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - SMS Login View

struct SMSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("netgsmUsername") private var storedUsername = ""
    @AppStorage("netgsmPassword") private var storedPassword = ""
    @AppStorage("netgsmHeader") private var storedHeader = ""
    @AppStorage("isSmsActive") private var isSmsActive = false
    
    @State private var username = ""
    @State private var password = ""
    @State private var msgHeader = ""
    
    @State private var availableHeaders: [String] = []
    @State private var isFetchingHeaders = false
    @State private var hasFetchedHeaders = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()
                
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.orange)
                            .shadow(color: .orange.opacity(0.5), radius: 10, x: 0, y: 5)
                        
                        Text("Netgsm Bağlantısı")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Lütfen Netgsm API kullanıcı adı ve şifrenizi girerek onaylı mesaj başlıklarınızı (Sender ID) listeleyin.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 20)
                    
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Kullanıcı Adı (Abone No)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.7))
                            TextField("Örn: 850304XXXX", text: $username)
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .onChange(of: username) { _ in resetHeaders() }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Şifresi")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.7))
                            SecureField("Şifrenizi girin", text: $password)
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                                .foregroundColor(.white)
                                .onChange(of: password) { _ in resetHeaders() }
                        }
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red)
                        }
                        
                        if !hasFetchedHeaders {
                            Button {
                                Task {
                                    await fetchHeaders()
                                }
                            } label: {
                                HStack {
                                    if isFetchingHeaders {
                                        ProgressView().tint(.white)
                                    }
                                    Text("Başlıkları Getir")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(username.isEmpty || password.isEmpty ? Color.white.opacity(0.1) : Color.blue)
                                .foregroundColor(username.isEmpty || password.isEmpty ? Color.white.opacity(0.3) : .white)
                                .cornerRadius(12)
                            }
                            .disabled(username.isEmpty || password.isEmpty || isFetchingHeaders)
                        }
                        
                        if hasFetchedHeaders && !availableHeaders.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Gönderici Başlığı Seçimi")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.orange)
                                
                                Picker("Gönderici Başlığı", selection: $msgHeader) {
                                    ForEach(availableHeaders, id: \.self) { header in
                                        Text(header).tag(header)
                                    }
                                }
                                .pickerStyle(.menu)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(12)
                                .tint(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    Button {
                        storedUsername = username
                        storedPassword = password
                        storedHeader = msgHeader
                        isSmsActive = true
                        dismiss()
                    } label: {
                        Text("Kaydet ve Aktifleştir")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(!hasFetchedHeaders || msgHeader.isEmpty ? Color.white.opacity(0.1) : Color.orange)
                            .foregroundColor(!hasFetchedHeaders || msgHeader.isEmpty ? Color.white.opacity(0.3) : .white)
                            .cornerRadius(16)
                            .shadow(color: !hasFetchedHeaders || msgHeader.isEmpty ? .clear : .orange.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!hasFetchedHeaders || msgHeader.isEmpty)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("İptal") { dismiss() }
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .onAppear {
                self.username = storedUsername
                self.password = storedPassword
                self.msgHeader = storedHeader
                if !storedUsername.isEmpty && !storedPassword.isEmpty && !storedHeader.isEmpty {
                    self.hasFetchedHeaders = true
                    self.availableHeaders = [storedHeader]
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func resetHeaders() {
        hasFetchedHeaders = false
        availableHeaders = []
        msgHeader = ""
        errorMessage = nil
    }
    
    private func fetchHeaders() async {
        isFetchingHeaders = true
        errorMessage = nil
        
        guard let url = URL(string: "https://api.netgsm.com.tr/sms/rest/v2/msgheader") else {
            isFetchingHeaders = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let safeUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let safePass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginString = "\(safeUser):\(safePass)"
        
        if let loginData = loginString.data(using: .utf8) {
            let base64LoginString = loginData.base64EncodedString()
            request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let code = json["code"] as? String, code == "00", let headers = json["msgheaders"] as? [String] {
                    await MainActor.run {
                        self.availableHeaders = headers
                        if let first = headers.first {
                            self.msgHeader = first
                        }
                        self.hasFetchedHeaders = true
                        self.isFetchingHeaders = false
                    }
                } else {
                    let desc = json["description"] as? String ?? "Bilinmeyen hata"
                    await MainActor.run {
                        self.errorMessage = "Hata: \(desc)"
                        self.isFetchingHeaders = false
                    }
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Sunucu yanıtı anlaşılamadı."
                    self.isFetchingHeaders = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Bağlantı hatası: \(error.localizedDescription)"
                self.isFetchingHeaders = false
            }
        }
    }
}
