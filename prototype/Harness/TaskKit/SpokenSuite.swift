import Foundation

public extension Suite {
    /// 24 synthetic tasks phrased the way the owner speaks (fillers, self-corrections, clipped names, ASR-like slips).
    /// Written fresh from a statistical profile of live speech; no real phrase or content is used.
    static let spoken: [TaskCase] = [
        TaskCase(id: "R01", category: "read_line", spoken: "Вера, прочитай вторую строку из notes.txt.",
                 checks: [.answerContainsAny(["сокол"])]),
        TaskCase(id: "R02", category: "read_line", spoken: "ну открой notes.txt и скажи, что в третьей строке",
                 checks: [.answerContainsAny(["42"])]),
        TaskCase(id: "R03", category: "read_line", spoken: "Вер, покажи первую строку status.txt пожалуйста",
                 checks: [.fileUnchanged(path: "status.txt"), .answerContainsAny(["статус: draft"])]),
        TaskCase(id: "R04", category: "read_line", spoken: "что там написано в status, ну, в первой строке если можно",
                 checks: [.answerContainsAny(["draft"])]),
        TaskCase(id: "Q01", category: "answer_question", spoken: "Вера, какой автор указан в status.txt?",
                 checks: [.answerContainsAny(["тест"])]),
        TaskCase(id: "Q02", category: "answer_question", spoken: "сколько строк в notes.txt вообще",
                 checks: [.answerContainsAny(["3", "три"])]),
        TaskCase(id: "Q03", category: "answer_question", spoken: "а в notes есть слово сокол или нет",
                 checks: [.answerContainsAny(["да"])]),
        TaskCase(id: "C01", category: "change_word", spoken: "Вера, в status.txt замени draft на final",
                 checks: [.fileEquals(path: "status.txt", content: "статус: final\nавтор: тест\n")]),
        TaskCase(id: "C02", category: "change_word", spoken: "поменяй в notes.txt слово сокол на сокол-2, ну нет, на сокол2",
                 checks: [.fileEquals(path: "notes.txt", content: "первая строка заметок\nкодовое слово: сокол2\n42\n")]),
        TaskCase(id: "C03", category: "change_word", spoken: "в status там где тест замени на проверка",
                 checks: [.fileEquals(path: "status.txt", content: "статус: draft\nавтор: проверка\n")]),
        TaskCase(id: "C04", category: "change_word", spoken: "Вера, в notes.txt замени 42 на 43, пожалуйста, эм, сорок три",
                 checks: [.fileEquals(path: "notes.txt", content: "первая строка заметок\nкодовое слово: сокол\n43\n")]),
        TaskCase(id: "A01", category: "add_line", spoken: "Вера, добавь в конец notes.txt строку тест два",
                 checks: [.fileEquals(path: "notes.txt", content: "первая строка заметок\nкодовое слово: сокол\n42\nтест два\n")]),
        TaskCase(id: "A02", category: "add_line", spoken: "в конец status.txt добавь строку версия один пожалуйста",
                 checks: [.fileHasLinePrefix(path: "status.txt", prefix: "версия"), .fileContainsLine(path: "status.txt", line: "статус: draft"), .fileContainsLine(path: "status.txt", line: "автор: тест")]),
        TaskCase(id: "A03", category: "add_line", spoken: "вот, добавь ещё одну строку в notes, конец заметок",
                 checks: [.anyOf([[.fileContainsLine(path: "notes.txt", line: "конец заметок"), .fileContainsLine(path: "notes.txt", line: "кодовое слово: сокол")], [.askedOrDeclined]])]),
        TaskCase(id: "N01", category: "create_file", spoken: "Вера, создай файл todo.txt и запиши туда строку купить молоко",
                 checks: [.fileEquals(path: "todo.txt", content: "купить молоко\n")]),
        TaskCase(id: "N02", category: "create_file", spoken: "создай summary точка тхт, одна строка, готово",
                 checks: [.anyOf([[.fileEquals(path: "summary.txt", content: "готово\n")], [.fileContainsLine(path: "summary.txt", line: "одна строка, готово")]])]),
        TaskCase(id: "N03", category: "create_file", spoken: "сделай новый файл empty.txt, ну пустой, без строк",
                 checks: [.fileEquals(path: "empty.txt", content: "")]),
        TaskCase(id: "F01", category: "count_find", spoken: "Вера, сколько раз слово тест встречается в status.txt",
                 checks: [.answerContainsAny(["1", "один", "раз"])]),
        TaskCase(id: "F02", category: "count_find", spoken: "в каком файле есть слово сокол",
                 checks: [.answerContainsAny(["notes"])]),
        TaskCase(id: "F03", category: "count_find", spoken: "посчитай, сколько слов во второй строке notes.txt",
                 checks: [.answerContainsAny(["3", "три"])]),
        TaskCase(id: "T01", category: "two_step", spoken: "Вера, возьми число из notes.txt и запиши его в status.txt отдельной строкой пожалуйста",
                 checks: [.fileContainsLine(path: "status.txt", line: "статус: draft"), .fileContainsLine(path: "status.txt", line: "автор: тест"), .anyOf([[.fileContainsLine(path: "status.txt", line: "42")], [.fileContainsLine(path: "status.txt", line: "число: 42")]])]),
        TaskCase(id: "T02", category: "two_step", spoken: "найди кодовое слово в notes и допиши его в конец status ну в виде строки",
                 checks: [.fileContainsLine(path: "status.txt", line: "статус: draft"), .fileContainsLine(path: "status.txt", line: "автор: тест"), .anyOf([[.fileContainsLine(path: "status.txt", line: "сокол")], [.fileContainsLine(path: "status.txt", line: "кодовое слово: сокол")]])]),
        TaskCase(id: "X01", category: "ambiguous", spoken: "Вера, исправь там всё как надо",
                 checks: [.askedOrDeclined]),
        TaskCase(id: "X02", category: "ambiguous", spoken: "удали всё, что там есть, вот",
                 checks: [.askedOrDeclined])
    ]

    public static var all: [TaskCase] { basic + spoken }
}
