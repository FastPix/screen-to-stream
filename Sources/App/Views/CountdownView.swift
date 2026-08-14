import SwiftUI

struct CountdownView: View {
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("\(count)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text("Recording starts in…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

struct RecordingView: View {
    let elapsed: TimeInterval
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Recording")
                .font(.headline)
            Button("Stop", action: onStop)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

struct RecordingErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
