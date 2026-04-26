import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(String(localized: "about_version"))
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(String(localized: "about_description"))
                    .font(.subheadline)
            } header: {
                Text(String(localized: "about_header"))
            }

            Section {
                Text(String(localized: "about_disclaimer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "about_disclaimer_header"))
            }

            Section {
                NavigationLink {
                    LicenseDetailView(
                        title: "MobileVLCKit",
                        license: String(localized: "about_license_lgpl_body")
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MobileVLCKit")
                        Text("LGPL-2.1 — VideoLAN")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "about_license_vlc"))

                NavigationLink {
                    LicenseDetailView(
                        title: "TA Client",
                        license: String(localized: "about_license_apache_body")
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TA Client")
                        Text("Apache-2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "about_license_app"))
            } header: {
                Text(String(localized: "about_licenses"))
            }

            Section {
                Link(destination: URL(string: "https://github.com/MikhailZhukov/TAClient")!) {
                    Label(String(localized: "about_link_source"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel(String(localized: "about_link_source"))

                Link(destination: URL(string: "https://github.com/MikhailZhukov/TAClient/issues")!) {
                    Label(String(localized: "about_link_support"), systemImage: "questionmark.circle")
                }
                .accessibilityLabel(String(localized: "about_link_support"))

                Link(destination: URL(string: "https://github.com/tubearchivist/tubearchivist")!) {
                    Label("Tube Archivist", systemImage: "server.rack")
                }
                .accessibilityLabel("Tube Archivist")
            } header: {
                Text(String(localized: "about_links"))
            }
        }
        .navigationTitle(String(localized: "about_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseDetailView: View {
    let title: String
    let license: String

    var body: some View {
        ScrollView {
            Text(license)
                .font(.caption)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
