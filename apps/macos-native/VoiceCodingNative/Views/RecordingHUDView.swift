import SwiftUI

struct RecordingHUDView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runtime: AppRuntimeState

    var body: some View {
        TimelineView(.animation(minimumInterval: refreshInterval, paused: !isAnimating)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate

            ZStack {
                if isAnimating {
                    PulseRingsView(
                        accentColor: accentColor,
                        level: pulseLevel,
                        phase: phase,
                        reduceMotion: reduceMotion
                    )
                }

                MicOrb(
                    accentColor: accentColor,
                    secondaryColor: secondaryAccentColor,
                    isAnimating: isAnimating,
                    phase: phase,
                    level: pulseLevel,
                    reduceMotion: reduceMotion
                )
            }
            .frame(width: 116, height: 116)
            .contentShape(Circle())
        }
    }

    private var isAnimating: Bool {
        runtime.isRecording || runtime.isTranscribing || runtime.pendingTranscriptionCount > 0
    }

    private var refreshInterval: TimeInterval {
        if runtime.isRecording {
            return 1.0 / 28.0
        }
        if runtime.isTranscribing || runtime.pendingTranscriptionCount > 0 {
            return 1.0 / 16.0
        }
        return 1.0 / 8.0
    }

    private var accentColor: Color {
        if runtime.isRecording {
            return Color(red: 0.96, green: 0.41, blue: 0.25)
        }
        if runtime.isTranscribing || runtime.pendingTranscriptionCount > 0 {
            return Color(red: 0.41, green: 0.58, blue: 0.96)
        }
        if runtime.status == .error {
            return Color(red: 0.84, green: 0.28, blue: 0.24)
        }
        return Color(red: 0.16, green: 0.67, blue: 0.56)
    }

    private var secondaryAccentColor: Color {
        if runtime.isRecording {
            return Color(red: 1.0, green: 0.70, blue: 0.28)
        }
        if runtime.isTranscribing || runtime.pendingTranscriptionCount > 0 {
            return Color(red: 0.71, green: 0.69, blue: 0.98)
        }
        if runtime.status == .error {
            return Color(red: 0.96, green: 0.55, blue: 0.50)
        }
        return Color(red: 0.49, green: 0.88, blue: 0.74)
    }

    private var pulseLevel: Double {
        if runtime.isRecording {
            return max(runtime.currentLevel, runtime.waveformSamples.max() ?? 0.12)
        }
        if runtime.isTranscribing || runtime.pendingTranscriptionCount > 0 {
            return 0.42
        }
        return 0.18
    }
}

private struct PulseRingsView: View {
    let accentColor: Color
    let level: Double
    let phase: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            ForEach(0 ..< 3, id: \.self) { index in
                let progress = ringProgress(for: index)
                Circle()
                    .stroke(
                        accentColor.opacity(reduceMotion ? 0.12 : (0.18 - progress * 0.14)),
                        lineWidth: reduceMotion ? 1.0 : 1.35
                    )
                    .frame(width: 48, height: 48)
                    .scaleEffect(
                        reduceMotion
                            ? 1.08 + CGFloat(index) * 0.10
                            : 1.05 + progress * (0.88 + level * 0.42) + CGFloat(index) * 0.05
                    )
            }
        }
    }

    private func ringProgress(for index: Int) -> Double {
        let raw = phase * 0.9 - Double(index) * 0.26
        let fractional = raw - floor(raw)
        return fractional
    }
}

private struct MicOrb: View {
    let accentColor: Color
    let secondaryColor: Color
    let isAnimating: Bool
    let phase: TimeInterval
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.09))
                .frame(width: 42, height: 42)
                .blur(radius: 9)

            Circle()
                .fill(.ultraThinMaterial.opacity(0.64))
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.82),
                                    secondaryColor.opacity(0.46),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .frame(width: 50, height: 50)
                .scaleEffect(scale)
                .shadow(color: accentColor.opacity(0.16), radius: 8, x: 0, y: 4)

            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            accentColor,
                            secondaryColor,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private var scale: CGFloat {
        guard isAnimating, !reduceMotion else {
            return 1.0
        }
        let oscillation = (sin(phase * 3.2) + 1) * 0.5
        return 0.95 + oscillation * (0.04 + level * 0.05)
    }
}

struct WaveformBarsView: View {
    let samples: [Double]
    let state: AppRuntimeState

    var body: some View {
        TimelineView(.animation(minimumInterval: state.isRecording ? 1.0 / 30.0 : 1.0 / 12.0, paused: false)) { context in
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(renderedSamples(at: context.date).enumerated()), id: \.offset) { index, sample in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tintColor.opacity(index.isMultiple(of: 2) ? 0.95 : 0.72),
                                    tintColor.opacity(0.30),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 7, height: max(8, 10 + sample * 32))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tintColor: Color {
        if state.isRecording {
            return Color(red: 0.97, green: 0.40, blue: 0.28)
        }
        if state.isTranscribing || state.pendingTranscriptionCount > 0 {
            return Color(red: 0.72, green: 0.67, blue: 0.98)
        }
        if state.status == .error {
            return Color(red: 0.84, green: 0.28, blue: 0.24)
        }
        return Color(red: 0.23, green: 0.74, blue: 0.59)
    }

    private func renderedSamples(at date: Date) -> [Double] {
        if state.isRecording {
            return samples.map { max(0.05, min(1.0, $0)) }
        }

        if state.isTranscribing || state.pendingTranscriptionCount > 0 {
            let phase = date.timeIntervalSinceReferenceDate * 5.2
            return samples.enumerated().map { index, _ in
                let oscillation = (sin(phase + Double(index) * 0.60) + 1) * 0.5
                return 0.20 + oscillation * 0.46
            }
        }

        return samples.map { _ in 0.07 }
    }
}
