import Testing
import TaskKit

@Suite("TaskBench answer checks")
struct TaskCheckerTests {
    @Test("a clarifying request without a question mark counts as asking")
    func clarifyingRequestCounts() {
        #expect(TaskRunner.asksOrDeclines("файл прочитала: три строки. скажи, какой текст дописать в конец, и я добавлю его отдельной строкой."))
        #expect(TaskRunner.asksOrDeclines("какое слово добавить?"))
    }

    @Test("a plain report of completed work does not count as asking")
    func completedWorkDoesNotCount() {
        #expect(!TaskRunner.asksOrDeclines("готово: summary.txt создан, одна строка."))
        #expect(!TaskRunner.asksOrDeclines("файл прочитала, там три строки."))
    }

    @Test("an explicit refusal counts as declining")
    func refusalCounts() {
        #expect(TaskRunner.asksOrDeclines("не буду удалять всё без подтверждения"))
    }
}
