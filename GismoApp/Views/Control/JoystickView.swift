import SwiftUI

struct JoystickView: View {
    @Binding var command: RobotCommand
    var onCommand: (RobotCommand) -> Void

    // Layout constants
    private let outerSize: CGFloat  = 276
    private let knobSize: CGFloat   = 104
    private let maxRadius: CGFloat  = 74

    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var lastCommand: RobotCommand = .stop

    var body: some View {
        ZStack {
            // Ambient glow when active
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.gAccent2.opacity(isDragging ? 0.25 : 0.06),
                            Color.gAccent.opacity(isDragging ? 0.14 : 0.02),
                            .clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 165
                    )
                )
                .frame(width: outerSize + 44, height: outerSize + 44)

            // Outer tactical telemetry ring (dashed)
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.gAccent2.opacity(isDragging ? 0.55 : 0.22),
                            Color.gAccent.opacity(isDragging ? 0.45 : 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 1.4, dash: [4, 8])
                )
                .frame(width: outerSize + 18, height: outerSize + 18)

            // Main housing base
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "101322"), Color.gSurface.opacity(0.96)],
                        center: .center,
                        startRadius: 10,
                        endRadius: outerSize / 2
                    )
                )
                .frame(width: outerSize, height: outerSize)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.gAccent2.opacity(isDragging ? 0.65 : 0.25),
                                    Color.gAccent.opacity(isDragging ? 0.45 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.8
                        )
                )
                .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 12)

            // Inner crosshair & deadzone ring
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                .frame(width: outerSize * 0.56, height: outerSize * 0.56)

            // Directional arrows (background guides)
            ForEach(Direction.allCases) { dir in
                directionArrow(dir)
            }

            // Tactile Core Knob
            ZStack {
                Circle()
                    .fill(
                        isDragging
                            ? LinearGradient(
                                colors: [Color.gAccent, Color.gAccent2],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.gSurface2, Color(hex: "121526")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        isDragging ? Color.white.opacity(0.55) : Color.white.opacity(0.18),
                                        isDragging ? Color.gCyan.opacity(0.4) : Color.white.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.8
                            )
                    )
                    .shadow(
                        color: isDragging ? Color.gAccent2.opacity(0.50) : Color.black.opacity(0.45),
                        radius: isDragging ? 20 : 12,
                        x: 0,
                        y: isDragging ? 0 : 6
                    )

                // Inner precision ring on knob
                Circle()
                    .stroke(Color.white.opacity(isDragging ? 0.25 : 0.08), lineWidth: 1)
                    .frame(width: knobSize - 22, height: knobSize - 22)

                Image(systemName: isDragging ? command.systemIcon : "scope")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(isDragging ? .white : .gAccent2.opacity(0.85))
            }
            .offset(knobOffset)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.74), value: knobOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    isDragging = true
                    let translation = value.translation
                    let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
                    let clamped = min(distance, maxRadius) / max(distance, 1)
                    let offset = CGSize(
                        width:  translation.width  * clamped,
                        height: translation.height * clamped
                    )
                    knobOffset = offset

                    let normalized = CGSize(
                        width:  translation.width  / maxRadius,
                        height: translation.height / maxRadius
                    )
                    let newCmd = commandFrom(dx: normalized.width, dy: normalized.height)
                    if newCmd != lastCommand {
                        lastCommand = newCmd
                        command = newCmd
                        onCommand(newCmd)
                        haptic()
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    knobOffset = .zero
                    lastCommand = .stop
                    command = .stop
                    onCommand(.stop)
                }
        )
    }

    // MARK: - Helpers

    private func commandFrom(dx: CGFloat, dy: CGFloat) -> RobotCommand {
        let magnitude = sqrt(dx * dx + dy * dy)
        guard magnitude > 0.3 else { return .stop }

        let angle = atan2(dy, dx) * (180 / .pi)
        switch angle {
        case -135 ..< -45:  return .forward
        case 45   ..< 135:  return .backward
        case -45  ..< 45:   return .right
        default:            return .left
        }
    }

    private func haptic() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    // MARK: - Direction Arrows

    private func directionArrow(_ dir: Direction) -> some View {
        let active = isActive(dir)
        let iconInset: CGFloat = outerSize / 2 - 28

        return ZStack {
            if active {
                Circle()
                    .fill(Color.gCyan.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .blur(radius: 4)
            }
            Image(systemName: dir.icon)
                .font(.system(size: 18, weight: .black))
                .foregroundColor(active ? .gCyan : Color.gSubtext.opacity(0.32))
                .scaleEffect(active ? 1.22 : 1.0)
        }
        .offset(x: dir.offsetX * iconInset,
                y: dir.offsetY * iconInset)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: command)
    }

    private func isActive(_ dir: Direction) -> Bool {
        switch (dir, command) {
        case (.up, .forward), (.down, .backward), (.left, .left), (.right, .right): return true
        default: return false
        }
    }
}

// MARK: - Direction helper

enum Direction: String, CaseIterable, Identifiable {
    case up, down, left, right
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .up:    return "chevron.up"
        case .down:  return "chevron.down"
        case .left:  return "chevron.left"
        case .right: return "chevron.right"
        }
    }

    var offsetX: CGFloat {
        switch self {
        case .left:  return -1
        case .right: return  1
        default:     return  0
        }
    }

    var offsetY: CGFloat {
        switch self {
        case .up:   return -1
        case .down: return  1
        default:    return  0
        }
    }
}

#Preview {
    ZStack {
        Color.gBg.ignoresSafeArea()
        JoystickView(command: .constant(.stop)) { cmd in
            print("Command:", cmd.rawValue)
        }
    }
}
