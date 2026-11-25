import Foundation
import PhoneWire

/// Hermes drives the player (plugin vera-phone → Vera → `VeraToPhone.music`): «включи Miyagi», «пауза», «дальше»,
/// «что играет». The phone finds the music in its own library — no list of tracks goes to Hermes; the answer is one
/// short sentence. Volume is not here: iOS gives apps no way to change it (the phone's or the headset's buttons).
extension Music {
    func command(_ c: PhoneMusicCommand) -> (Bool, String) {
        switch c.action {
        case "play":
            return play(query: (c.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "pause":
            guard playing else { return (true, "музыка и так не играет") }
            pause()
            return (true, "пауза: \(Self.line(current))")
        case "resume":
            guard !playing else { return (true, "уже играет: \(Self.line(current))") }
            guard current != nil || !tracks.isEmpty else { return (false, "в медиатеке телефона пока нет треков") }
            toggle()
            return (true, "играет: \(Self.line(current))")
        case "next":
            guard current != nil else { return (false, "сейчас ничего не играет") }
            next()
            return (true, "дальше: \(Self.line(current))")
        case "previous":
            guard current != nil else { return (false, "сейчас ничего не играет") }
            previous()
            return (true, "назад: \(Self.line(current))")
        case "status":
            guard let t = current else { return (true, "ничего не играет; в медиатеке \(tracks.count) треков") }
            return (true, "\(playing ? "играет" : "на паузе"): \(Self.line(t)) · \(t.format) · в медиатеке \(tracks.count) треков")
        default:
            return (false, "не знаю действия «\(c.action)»")
        }
    }

    /// What to play for what was said: an artist (all of theirs), an album (in order), a track — exact names first,
    /// then a name that contains the words. Nothing said — «Моё любимое».
    private func play(query q: String) -> (Bool, String) {
        guard !tracks.isEmpty else { return (false, "в медиатеке телефона пока нет треков") }
        if q.isEmpty, let fav = library.playlists.first, let first = fav.tracks.first {
            play(first, from: fav.tracks)
            return (true, "«\(fav.name)», \(fav.tracks.count) треков: \(Self.line(first))")
        }
        let same: (String) -> Bool = { $0.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let has: (String) -> Bool = { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if let a = library.artists.first(where: { same($0.name) }) ?? library.artists.first(where: { has($0.name) }),
           let first = a.tracks.first {
            play(first, from: a.tracks)
            return (true, "\(a.name), \(a.tracks.count) треков: \(Self.line(first))")
        }
        if let al = library.albums.first(where: { same($0.name) }) ?? library.albums.first(where: { has($0.name) }),
           let first = al.tracks.first {
            play(first, from: al.tracks)
            return (true, "альбом «\(al.name)» (\(al.artist)), \(al.tracks.count) треков: \(Self.line(first))")
        }
        let found = search(q)
        if let t = found.first(where: { same($0.title) }) ?? found.first {
            play(t, from: found)
            return (true, "\(Self.line(t))\(found.count > 1 ? " · ещё \(found.count - 1) похожих в очереди" : "")")
        }
        return (false, "в медиатеке телефона нет «\(q)» — ни исполнителя, ни альбома, ни трека")
    }

    private static func line(_ t: Track?) -> String {
        guard let t else { return "—" }
        return t.artist.isEmpty ? "«\(t.title)»" : "«\(t.title)» — \(t.artist)"
    }
}
