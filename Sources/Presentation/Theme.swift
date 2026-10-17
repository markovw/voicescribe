import SwiftUI

let ink = Color(red: 5/255, green: 5/255, blue: 5/255)
let panel = ink
let textColor = Color(red: 214/255, green: 214/255, blue: 214/255)
let muted = Color(red: 151/255, green: 151/255, blue: 151/255)
let rule = Color(red: 32/255, green: 32/255, blue: 32/255)
let soft = Color(red: 17/255, green: 17/255, blue: 17/255)
let accent = Color(red: 216/255, green: 134/255, blue: 126/255)
let palette: [Color] = [accent, Color(red: 168/255, green: 213/255, blue: 162/255),
    Color(red: 163/255, green: 185/255, blue: 208/255), Color(red: 207/255, green: 187/255, blue: 151/255)]

func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    Font.system(size: size, weight: weight)
}

struct QuietButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(uiFont(14)).padding(.horizontal, 13).padding(.vertical, 10)
            .foregroundStyle(primary ? ink : textColor)
            .background(primary ? textColor : (configuration.isPressed ? rule : soft))
            .overlay(Rectangle().stroke(primary ? textColor : rule, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

