import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(AppRouter.self) private var router

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "settings_sponsorblock_enabled"),
                    isOn: viewModel.sponsorBlockEnabledBinding
                )
                .accessibilityLabel(String(localized: "settings_sponsorblock_enabled"))
            } header: {
                Text(String(localized: "settings_sponsorblock"))
            } footer: {
                Text(String(localized: "settings_sponsorblock_description"))
            }

            if viewModel.isSponsorBlockEnabled {
                Section {
                    ForEach(SponsorCategory.allCases) { category in
                        Toggle(
                            category.label,
                            isOn: viewModel.binding(for: category)
                        )
                        .accessibilityLabel(category.label)
                    }
                } header: {
                    Text(String(localized: "settings_sponsorblock_categories"))
                }
            }
            Section {
                Toggle(
                    String(localized: "settings_double_tap_seek"),
                    isOn: viewModel.doubleTapToSeekBinding
                )
                .accessibilityLabel(String(localized: "settings_double_tap_seek"))

                if viewModel.isDoubleTapToSeekEnabled {
                    Picker(
                        String(localized: "settings_seek_interval"),
                        selection: viewModel.seekIntervalBinding
                    ) {
                        ForEach(SponsorBlockSettings.seekIntervalOptions, id: \.self) { interval in
                            Text(String(localized: "settings_seek_seconds \(interval)")).tag(interval)
                        }
                    }
                    .accessibilityLabel(String(localized: "settings_seek_interval"))
                }
            } header: {
                Text(String(localized: "settings_player"))
            }

            Section {
                Button {
                    router.navigate(to: .about)
                } label: {
                    HStack {
                        Text(String(localized: "settings_about"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "settings_about"))
            }
        }
        .navigationTitle(String(localized: "settings_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
