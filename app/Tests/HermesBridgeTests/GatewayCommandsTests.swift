import Testing
@testable import HermesBridge

/// Offline: typed commands go where Hermes' own gateway client sends them.
struct GatewayCommandsTests {
    @Test func sessionChangesAreMutations() {
        #expect(GatewayCommand.route("/model deepseek-v4.1-flash") == .mutate(operation: "model", payload: ["model": .string("deepseek-v4.1-flash")]))
        #expect(GatewayCommand.route("/model m --provider opencode-go")
                == .mutate(operation: "model", payload: ["model": .string("m"), "provider": .string("opencode-go")]))
        #expect(GatewayCommand.route("/title Вера") == .mutate(operation: "rename", payload: ["title": .string("Вера")]))
        #expect(GatewayCommand.route("/compress") == .mutate(operation: "compress", payload: [:]))
        #expect(GatewayCommand.route("/compact here 4 --preview")
                == .mutate(operation: "compress", payload: ["partial": .bool(true), "keep_last": .number(4), "preview": .bool(true)]))
        #expect(GatewayCommand.route("/compress музыка") == .mutate(operation: "compress", payload: ["focus": .string("музыка")]))
    }

    @Test func controlsAndRefusals() {
        #expect(GatewayCommand.route("/stop") == .interrupt)
        #expect(GatewayCommand.route("/undo 2") == .rewind(turns: 2, retry: false))
        #expect(GatewayCommand.route("/retry") == .rewind(turns: 1, retry: true))
        #expect(GatewayCommand.route("/yolo on") == .yolo(on: true))
        #expect(GatewayCommand.route("/model") == .showModel)
        if case .problem = GatewayCommand.route("/model x --global") {} else { Issue.record("--global must be refused") }
        if case .unavailable = GatewayCommand.route("/new") {} else { Issue.record("/new is not Vera's") }
        if case .unavailable = GatewayCommand.route("/branch x") {} else { Issue.record("/branch is not Vera's") }
    }

    @Test func reportsGoToTheGateway() {
        #expect(GatewayCommand.route("/usage") == .exec("usage"))
        #expect(GatewayCommand.route("/title") == .exec("title"))
        #expect(GatewayCommand.route("/skills list") == .exec("skills list"))
    }

    @Test func rewindTargetsOnlyTypedLiveTurns() {
        let snap: JSONValue = .object(["messages": .array([
            .object(["role": .string("user"), "row_id": .number(1)]),
            .object(["role": .string("assistant"), "row_id": .number(2)]),
            .object(["role": .string("user"), "row_id": .number(3), "archived": .bool(true)]),
            .object(["role": .string("user"), "row_id": .number(4), "display_kind": .string("notice")]),
            .object(["role": .string("user"), "row_id": .number(5), "display_kind": .string("steer")]),
        ])])
        #expect(GatewayCommand.userTurnIds(snap) == [1, 5])
    }
}
