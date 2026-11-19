import AppKit
import Observation
import SwiftUI

/// Colors of Vera's main window (copied from App/ContentView.swift, not imported).
enum BrowserPalette {
    static let background = Color(red: 0.035, green: 0.025, blue: 0.047)
    static let accent = Color(red: 0.94, green: 0.13, blue: 0.61)
    static let bar = Color.black.opacity(0.16)
    static let nsBackground = NSColor(red: 0.035, green: 0.025, blue: 0.047, alpha: 1)
}

/// What the toolbar shows about the page. Written by the engine, read by the toolbar.
@MainActor
@Observable
final class BrowserChrome {
    var url = ""
    var title = ""
    var isLoading = false
    var canGoBack = false

    func reset() {
        url = ""; title = ""; isLoading = false; canGoBack = false
    }
}

/// The slim toolbar above her page: back, reload, the address (read-only), a status line and the hide button.
struct BrowserChromeView: View {
    let chrome: BrowserChrome
    let onBack: () -> Void
    let onReload: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", label: "Назад", enabled: chrome.canGoBack, action: onBack)
            iconButton("arrow.clockwise", label: "Обновить", enabled: true, action: onReload)
            Text(chrome.url.isEmpty ? "—" : chrome.url)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Адрес страницы")
            Text(status)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .frame(maxWidth: 240, alignment: .trailing)
            Button(action: onHide) {
                Text("Скрыть")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(BrowserPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Скрыть окно браузера; Вера продолжает работать")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(BrowserPalette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var status: String {
        if chrome.isLoading { return "ЗАГРУЗКА…" }
        return chrome.title.isEmpty ? "ГОТОВО" : chrome.title
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }
}
