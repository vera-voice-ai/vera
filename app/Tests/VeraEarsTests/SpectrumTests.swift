import Foundation
import Testing
@testable import VeraEars

@Suite struct SpectrumTests {
    /// A 1 kHz tone lands in the band of 1 kHz (125 Hz per band), one column per 20 ms.
    @Test func aToneLightsItsBand() {
        let s = Spectrum()
        let tone = (0..<1600).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
        let columns = s.feed(tone)
        #expect(columns.count == 4)   // the first 512 samples fill the window; then a column every 320
        let last = columns.last!
        #expect(last.count == Spectrum.bands)
        let loudest = last.indices.max { last[$0] < last[$1] }!
        #expect(loudest == 1000 * Spectrum.bands / 8000)
        #expect(last[loudest] > -12 && last[40] < last[loudest] - 40)
    }

    @Test func silenceStaysDark() {
        let columns = Spectrum().feed([Float](repeating: 0, count: 960))
        #expect(columns.allSatisfy { $0.allSatisfy { $0 == -100 } })
    }
}
