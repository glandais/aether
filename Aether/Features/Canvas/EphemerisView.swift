import SwiftUI

/// Éphéméride du lieu et du jour courants : lever / coucher du Soleil et de la
/// Lune (heure locale), phase et visibilité de la Lune. Feuille sobre.
struct EphemerisView: View {
    let ephemeris: Ephemeris
    let timeZone: TimeZone

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    luminary(
                        ephemeris.sun, nameKey: "ephemeris.sun",
                        riseKey: "ephemeris.sunrise", setKey: "ephemeris.sunset",
                        riseIcon: "sunrise", setIcon: "sunset")
                }
                Section {
                    luminary(
                        ephemeris.moon, nameKey: "ephemeris.moon",
                        riseKey: "ephemeris.moonrise", setKey: "ephemeris.moonset",
                        riseIcon: "moon", setIcon: "moon.fill")
                    row("ephemeris.phase", icon: phaseIcon, value: phaseName)
                    row("ephemeris.illumination", icon: "circle.lefthalf.filled", value: illumination)
                }
            }
            .navigationTitle(Text("ephemeris.title", tableName: "Aether"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.confirm", table: "Aether")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Rend un astre : deux lignes lever/coucher, ou une ligne « au-dessus / sous
    /// l'horizon » quand il est circumpolaire (soleil de minuit, nuit polaire).
    @ViewBuilder
    private func luminary(
        _ state: RiseSetState, nameKey: String.LocalizationValue,
        riseKey: String.LocalizationValue, setKey: String.LocalizationValue,
        riseIcon: String, setIcon: String
    ) -> some View {
        switch state {
        case let .rises(rise, set):
            row(riseKey, icon: riseIcon, value: time(rise))
            row(setKey, icon: setIcon, value: time(set))
        case .alwaysUp:
            row(nameKey, icon: riseIcon,
                value: String(localized: "ephemeris.alwaysUp", table: "Aether"))
        case .alwaysDown:
            row(nameKey, icon: setIcon,
                value: String(localized: "ephemeris.alwaysDown", table: "Aether"))
        }
    }

    private func row(_ titleKey: String.LocalizationValue, icon: String, value: String) -> some View {
        LabeledContent {
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.primary)
        } label: {
            Label {
                Text(String(localized: titleKey, table: "Aether"))
            } icon: {
                Image(systemName: icon).foregroundStyle(.secondary)
            }
        }
    }

    /// Heure locale « HH:mm », ou « — » si l'astre ne franchit pas l'horizon ce jour.
    private func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var phaseName: String {
        String(localized: ephemeris.moonPhase.labelKey, table: "Aether")
    }

    private var phaseIcon: String { ephemeris.moonPhase.symbolName }

    private var illumination: String {
        "\(Int((ephemeris.moonIllumination * 100).rounded())) %"
    }
}

private extension LunarPhase {
    /// Clé de localisation du terme de phase (table `Aether`).
    var labelKey: String.LocalizationValue {
        switch self {
        case .newMoon: "moon.new"
        case .waxingCrescent: "moon.waxingCrescent"
        case .firstQuarter: "moon.firstQuarter"
        case .waxingGibbous: "moon.waxingGibbous"
        case .fullMoon: "moon.full"
        case .waningGibbous: "moon.waningGibbous"
        case .lastQuarter: "moon.lastQuarter"
        case .waningCrescent: "moon.waningCrescent"
        }
    }

    /// Symbole SF reproduisant la phase.
    var symbolName: String {
        switch self {
        case .newMoon: "moonphase.new.moon"
        case .waxingCrescent: "moonphase.waxing.crescent"
        case .firstQuarter: "moonphase.first.quarter"
        case .waxingGibbous: "moonphase.waxing.gibbous"
        case .fullMoon: "moonphase.full.moon"
        case .waningGibbous: "moonphase.waning.gibbous"
        case .lastQuarter: "moonphase.last.quarter"
        case .waningCrescent: "moonphase.waning.crescent"
        }
    }
}
