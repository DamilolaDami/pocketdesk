import Testing
import PDProtocol
@testable import PDClientCore

struct MacCardInfoTests {
    @Test func gradesTheRoundTrip() {
        #expect(ConnectionGrade(latency: .milliseconds(3)) == .excellent)
        #expect(ConnectionGrade(latency: .milliseconds(20)) == .good)
        #expect(ConnectionGrade(latency: .milliseconds(90)) == .fair)
        #expect(ConnectionGrade(latency: .milliseconds(400)) == .poor)
    }

    @Test func latencyText() {
        #expect(Duration.microseconds(400).latencyText == "<1 ms")
        #expect(Duration.microseconds(4_400).latencyText == "4 ms")
        #expect(Duration.milliseconds(120).latencyText == "120 ms")
    }

    @Test func battery() {
        #expect(MacBattery(level: 82, isCharging: false, onPower: false).symbol == "battery.75percent")
        #expect(MacBattery(level: 5, isCharging: false, onPower: false).symbol == "battery.0percent")
        #expect(MacBattery(level: 40, isCharging: true, onPower: true).symbol == "battery.100percent.bolt")
        #expect(MacBattery(level: 15, isCharging: false, onPower: false).isLow)
        #expect(!MacBattery(level: 15, isCharging: true, onPower: true).isLow)
        #expect(MacBattery(level: 80, isCharging: false, onPower: true).text == "80%, on power")
    }

    @Test func playersOnThePhone() {
        #expect(PlayerApp(bundleID: "com.spotify.client", name: "Spotify").phoneURL == "spotify:")
        #expect(PlayerApp(bundleID: "com.apple.Music", name: "Music").phoneURL == "music:")
        // A video in a browser has nothing to open on the phone.
        #expect(PlayerApp(bundleID: "com.apple.Safari", name: "Safari").phoneURL == nil)
    }

    @Test func copiedNotice() {
        #expect(ClipboardItem.copiedNotice(ClipboardItem(text: "  Meeting at 3\nRoom 2"), from: "Studio")
                == "Copied “Meeting at 3” from Studio")
        #expect(ClipboardItem.copiedNotice(ClipboardItem(text: String(repeating: "a", count: 50)), from: "Studio")
                == "Copied “\(String(repeating: "a", count: 40))…” from Studio")
        #expect(ClipboardItem.copiedNotice(ClipboardItem(png: "AAAA"), from: "Studio") == "Copied an image from Studio")
    }
}
