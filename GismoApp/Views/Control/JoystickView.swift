import SwiftUI

struct JoystickView: View {
    @Binding var command: RobotCommand
    var onCommand: (RobotCommand) -> Void

    // Layout constants
    private let outerSize: CGFloat  = 260
    private let knobSize: CGFloat   = 100
    private let maxRadius: CGFloat  = 70

    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var lastCommand: RobotCommand = .stop

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .fill(Color.gSurface)
                .frame(width: outerSize, height: outerSize)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.gAccent.opacity(isDragging ? 0.5 : 0.2),
                                    Color.gAccent2.opacity(isDragging ? 0.3 : 0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: Color.gAccent.opacity(isDragging ? 0.2 : 0), radius: 20)

            // Directional arrows (background guides)
            ForEach(Direction.allCases) { dir in
                directionArrow(dir)
            }

            // Knob
            Circle()
                .fill(
                    isDragging
                        ? LinearGradient.accent
                        : LinearGradient(colors: [Color.gSurface2, Color.gSurface],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: knobSize, height: knobSize)
                .overlay(
                    Circle()
                        .stroke(
                            isDragging
                                ? Color.white.opacity(0.2)
                                : Color.gBorder,
                            lineWidth: 1.5
                        )
                )
                .overlay(
                    Image(systemName: "circle.grid.cross.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(isDragging ? .white.opacity(0.9) : .gSubtext)
                )
                .shadow(color: isDragging ? Color.gAccent.opacity(0.4) : .clear, radius: 20)
                .offset(knobOffset)
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.75), value: knobOffset)
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

                    // Compute command
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
        let iconSize: CGFloat = 18
        let iconInset: CGFloat = outerSize / 2 - 28

        return Image(systemName: dir.icon)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundColor(isActive(dir) ? .gAccent : Color.gSubtext.opacity(0.3))
            .offset(x: dir.offsetX * iconInset / outerSize * outerSize,
                    y: dir.offsetY * iconInset / outerSize * outerSize)
            .animation(.easeInOut(duration: 0.1), value: command)
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
