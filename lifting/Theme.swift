// Theme.swift
// App-wide colors and shared UI helpers

import SwiftUI

extension Color {
    static let appBg       = Color(red: 0.047, green: 0.047, blue: 0.047)
    static let appCard     = Color(red: 0.094, green: 0.094, blue: 0.094)
    static let appCard2    = Color(red: 0.141, green: 0.141, blue: 0.141)
    static let appBorder   = Color(red: 0.165, green: 0.165, blue: 0.165)
    static let appAccent   = Color(red: 0.961, green: 0.902, blue: 0.259)  // #F5E642
    static let appMuted    = Color(red: 0.40,  green: 0.40,  blue: 0.40)
    static let appMuted2   = Color(red: 0.60,  green: 0.60,  blue: 0.60)
    static let appGreen    = Color(red: 0.306, green: 0.796, blue: 0.443)
    static let appRed      = Color(red: 1.00,  green: 0.267, blue: 0.267)
}

// Category dot colors
func categoryColor(_ category: String) -> Color {
    switch category {
    case "Chest":     return Color(red: 1.0,   green: 0.42,  blue: 0.42)
    case "Back":      return Color(red: 0.306, green: 0.804, blue: 0.769)
    case "Legs":      return Color(red: 0.271, green: 0.718, blue: 0.820)
    case "Shoulders": return Color(red: 0.588, green: 0.808, blue: 0.706)
    case "Arms":      return Color(red: 1.0,   green: 0.820, blue: 0.400)
    case "Core":      return Color(red: 0.780, green: 0.478, blue: 1.0)
    default:          return Color.appMuted
    }
}

// Reusable primary button style
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.appAccent)
            .cornerRadius(14)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.appCard2)
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Section header style
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.appMuted)
            .kerning(1.0)
    }
}

// Stat card
struct StatCard: View {
    let value: String
    let sub: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            Text(sub)
                .font(.system(size: 11))
                .foregroundColor(.appMuted)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.appMuted2)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appCard)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
    }
}
