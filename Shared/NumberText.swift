import Foundation

extension BinaryInteger {
    /// The number as it reads on screen: digits grouped in threes by a narrow no-break space ("2 589 690"), the same in
    /// every region, so a dot only ever means a decimal point. Up to four digits stay together ("2048"). Text that a
    /// script or an agent reads, a slider's value and a text field's take the bare digits instead.
    var spaced: String {
        let digits = String(magnitude)
        guard digits.count > 4 else { return String(self) }
        var grouped = ""
        for (i, digit) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 {
                grouped.append("\u{202F}")
            }
            grouped.append(digit)
        }
        return self < 0 ? "-" + grouped : grouped
    }
}
