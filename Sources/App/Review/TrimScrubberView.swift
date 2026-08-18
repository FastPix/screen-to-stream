import SwiftUI

/// Track with a live playhead and two draggable trim handles. Clamping is delegated to
/// TrimRange; this view only maps x-position ↔ seconds.
struct TrimScrubberView: View {
    let currentTime: Double
    @Binding var trim: TrimRange
    let onSeek: (Double) -> Void

    private let handleWidth: CGFloat = 10
    private let trackHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let duration = max(trim.duration, 0.0001)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)

                    keptRegion(width: width, duration: duration)
                    playhead(width: width, duration: duration)
                    handle(isStart: true, width: width, duration: duration)
                    handle(isStart: false, width: width, duration: duration)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        onSeek(seconds(forX: value.location.x, width: width, duration: duration))
                    }
                )
            }
            .frame(height: trackHeight)

            HStack {
                Text(timecode(trim.start))
                Spacer()
                if !trim.isNoop {
                    Text("keeps \(timecode(trim.trimmedLength)) of \(timecode(trim.duration))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timecode(trim.end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func keptRegion(width: CGFloat, duration: Double) -> some View {
        let startX = x(forSeconds: trim.start, width: width, duration: duration)
        let endX = x(forSeconds: trim.end, width: width, duration: duration)

        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(0.30))
            .frame(width: max(0, endX - startX), height: trackHeight)
            .offset(x: startX)
    }

    private func playhead(width: CGFloat, duration: Double) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 2, height: 16)
            .offset(x: x(forSeconds: currentTime, width: width, duration: duration) - 1)
    }

    private func handle(isStart: Bool, width: CGFloat, duration: Double) -> some View {
        let seconds = isStart ? trim.start : trim.end

        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: trackHeight)
            .offset(x: x(forSeconds: seconds, width: width, duration: duration) - handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let t = self.seconds(forX: value.location.x, width: width, duration: duration)
                    if isStart { trim.moveStart(to: t) } else { trim.moveEnd(to: t) }
                }
                .onEnded { _ in onSeek(trim.start) }
            )
    }

    private func x(forSeconds seconds: Double, width: CGFloat, duration: Double) -> CGFloat {
        CGFloat(seconds / duration) * width
    }

    private func seconds(forX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(min(max(0, x), width) / width) * duration
    }

    private func timecode(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}
