import AppKit
import PappuCore
import SwiftUI

/// The first-run window's three screens (ONB-1, ONB-4).
///
/// One view with a switch rather than three windows, because the screens replace one another in place:
/// the user reads what the app does, presses Continue, and the same window becomes the permission
/// request. Nothing here decides *which* screen to show — `OnboardingModel` watches the grant and the
/// view follows it, which is how the permission screen disappears the moment the permission arrives
/// without anything having to be pressed.
///
/// There is no test for this file, as the house style has it for AppKit and SwiftUI surfaces: every
/// sentence it says comes from `AppStrings` and every decision it makes came from the model.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            switch model.screen {
            case .welcome:
                screen(
                    title: AppStrings.onboardingWelcomeTitle,
                    body: AppStrings.onboardingWelcomeBody,
                    button: AppStrings.onboardingWelcomeContinue,
                    action: { model.welcomeRead() }
                )
            case .permission:
                screen(
                    title: AppStrings.onboardingPermissionTitle,
                    body: AppStrings.onboardingPermissionBody,
                    button: AppStrings.onboardingPermissionOpen,
                    action: { model.openAccessibilityPane() },
                    footnote: AppStrings.onboardingPermissionWaiting
                )
            case .repair:
                screen(
                    title: AppStrings.onboardingRepairTitle,
                    body: AppStrings.onboardingRepairBody,
                    button: AppStrings.onboardingPermissionOpen,
                    action: { model.openAccessibilityPane() },
                    footnote: AppStrings.onboardingPermissionWaiting
                )
            case .none:
                // Reached for the moment between the grant arriving and the window closing itself.
                EmptyView()
            }
        }
        .padding(32)
        .frame(width: 460)
    }

    @ViewBuilder
    private func screen(
        title: String,
        body: String,
        button: String,
        action: @escaping () -> Void,
        footnote: String? = nil
    ) -> some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)

        Text(body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Button(button, action: action)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

        if let footnote {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
