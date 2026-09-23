import SwiftUI

/// A restrained transition for supporting values that should not compete with
/// quota percentages and currency amounts.
struct BasicValueText: View {
    let value: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: String
    @State private var isVisible = false
    @State private var transitionID = UUID()

    init(_ value: String) {
        self.value = value
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        Text(displayedValue)
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 3)
            .accessibilityLabel(displayedValue)
            .onAppear { reveal(value) }
            .onChange(of: value) { newValue in reveal(newValue) }
    }

    private func reveal(_ newValue: String) {
        let identifier = UUID()
        transitionID = identifier
        if reduceMotion {
            displayedValue = newValue
            isVisible = true
            return
        }
        withAnimation(.easeOut(duration: 0.1)) { isVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard transitionID == identifier else { return }
            displayedValue = newValue
            withAnimation(.easeOut(duration: 0.18)) { isVisible = true }
        }
    }
}

/// An odometer-style value transition. Changed digits travel through every
/// intermediate digit instead of replacing the whole string at once.
struct RollingNumberText: View {
    let value: String

    @State private var characters: [Character]
    @State private var direction = 0

    init(_ value: String) {
        self.value = value
        _characters = State(initialValue: Array(value))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                if let digit = character.wholeNumberValue {
                    OdometerDigit(digit: digit, direction: direction)
                } else {
                    Text(String(character))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value)
        .onChange(of: value) { newValue in
            direction = Self.numericDirection(from: String(characters), to: newValue)
            characters = Array(newValue)
        }
    }

    private static func numericDirection(from oldValue: String, to newValue: String) -> Int {
        guard let oldNumber = numericValue(in: oldValue),
              let newNumber = numericValue(in: newValue),
              oldNumber != newNumber else { return 0 }
        return newNumber > oldNumber ? 1 : -1
    }

    private static func numericValue(in text: String) -> Double? {
        var result = ""
        var hasDecimalPoint = false
        for character in text {
            if character.isNumber || (character == "-" && result.isEmpty) {
                result.append(character)
            } else if character == "." && !hasDecimalPoint {
                result.append(character)
                hasDecimalPoint = true
            }
        }
        return Double(result)
    }
}

private struct OdometerDigit: View {
    let digit: Int
    let direction: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [Int]
    @State private var progress = 0.0
    @State private var transitionID = UUID()
    @State private var hasAppeared = false

    init(digit: Int, direction: Int) {
        self.digit = digit
        self.direction = direction
        _path = State(initialValue: [0])
    }

    var body: some View {
        Text("8")
            .hidden()
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        ForEach(Array(path.enumerated()), id: \.offset) { index, value in
                            Text(String(value))
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .offset(y: CGFloat(Double(index) - progress) * geometry.size.height)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
            }
            .onChange(of: digit) { newDigit in
                roll(to: newDigit)
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                roll(to: digit)
            }
    }

    private func roll(to newDigit: Int) {
        let oldDigit = path.last ?? newDigit
        guard oldDigit != newDigit else { return }

        if reduceMotion {
            path = [newDigit]
            progress = 0
            return
        }

        let identifier = UUID()
        transitionID = identifier
        path = digitPath(from: oldDigit, to: newDigit)
        progress = 0
        let finalProgress = Double(path.count - 1)
        let duration = min(0.5, max(0.24, finalProgress * 0.1))

        DispatchQueue.main.async {
            guard transitionID == identifier else { return }
            withAnimation(.easeInOut(duration: duration)) {
                progress = finalProgress
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
            guard transitionID == identifier else { return }
            path = [newDigit]
            progress = 0
        }
    }

    private func digitPath(from oldDigit: Int, to newDigit: Int) -> [Int] {
        let rollingDirection = direction == 0 ? (newDigit > oldDigit ? 1 : -1) : direction
        var result = [oldDigit]
        var current = oldDigit
        while current != newDigit {
            current = (current + rollingDirection + 10) % 10
            result.append(current)
        }
        return result
    }
}
