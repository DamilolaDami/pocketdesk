#if os(macOS)
import Testing
@testable import PDHostCore

struct OnboardingTests {
    @Test func stepsGoInOrder() {
        #expect(OnboardingStep.welcome.next == .screenRecording)
        #expect(OnboardingStep.pair.next == .done)
        #expect(OnboardingStep.wakeAndLogin.next == .iPhoneApp)
        #expect(OnboardingStep.iPhoneApp.next == .pair)
        #expect(OnboardingStep.pair.previous == .iPhoneApp)
        #expect(OnboardingStep.done.next == nil)
        #expect(OnboardingStep.welcome.previous == nil)
    }

    @Test func skipsPermissionsAlreadyGranted() {
        #expect(OnboardingStep.welcome.advanced { _ in true } == .wakeAndLogin)
        #expect(OnboardingStep.welcome.advanced { $0 == .screenRecording } == .accessibility)
        #expect(OnboardingStep.welcome.advanced { _ in false } == .screenRecording)
        #expect(OnboardingStep.pair.advanced { _ in true } == .done)
        #expect(OnboardingStep.wakeAndLogin.advanced { _ in true } == .iPhoneApp)
        #expect(OnboardingStep.iPhoneApp.advanced { _ in false } == .pair)
    }
}
#endif
