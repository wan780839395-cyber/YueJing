import Foundation
import Testing
@testable import ReaderDomain

struct StoryGenerationTests {
    @Test func lockedPresetDrivesConfirmedPayloadAndOnlyCompletedModelTurnPersists() async throws {
        try await checkStoryModelTransport()
        let proxied = try StoryModelCatalog.url(endpoint: "https://gateway.invalid:9443/tenant/v1/chat/completions/")
        #expect(proxied.absoluteString == "https://gateway.invalid:9443/tenant/v1/models")
        #expect(throws: (any Error).self) { try StoryModelCatalog.url(endpoint: "http://192.168.1.3/v1/chat/completions") }
        #expect(throws: (any Error).self) { try StoryModelCatalog.url(endpoint: "https://gateway.invalid/agent/run") }
        let base = "http://172.31.0.1:8080/tenant-A/v1"
        let chat = base + "/chat/completions"
        let models = base + "/models"
        for input in [base, base + "/", chat, chat + "/"] {
            #expect(StoryModelVault.lanEndpointCandidate(input) == chat)
            #expect(try StoryModelCatalog.url(endpoint: input, approvedLANEndpoint: chat).absoluteString == models)
        }
        for host in ["10.0.0.1", "172.16.0.0", "172.31.255.255", "192.168.255.254"] {
            let direct = "http://\(host)/chat/completions"
            #expect(StoryModelVault.lanEndpointCandidate(direct) == direct)
        }
        for host in ["127.0.0.1", "8.8.8.8", "172.15.255.255", "172.32.0.0", "192.169.0.0", "169.254.1.1",
                     "localhost", "router.local", "[::ffff:10.0.0.1]", "10.1", "167772161", "0xa.0.0.1", "010.0.0.1",
                     "10.0.0.01", "10.0.0.256", "10.0.0.1.", "10.%30.0.1", "user:pass@10.0.0.1", "10.0.0.1:080", "10.0.0.1:65536"] {
            #expect(StoryModelVault.lanEndpointCandidate("http://\(host)/v1") == nil)
        }
        for path in ["/v1?", "/v1#", "/v1/chat/completions?x=1", "/../v1", "/a/./v1", "//v1", "/%2e%2e/v1",
                     "/a%2Fb/v1", "/a\\b/v1", "/a;b/v1", "/x y/v1", "/v1/models", "/v1//"] {
            #expect(StoryModelVault.lanEndpointCandidate("http://10.0.0.1" + path) == nil)
        }
        for wrong in [base, models, chat + "/", chat.replacingOccurrences(of: "tenant-A", with: "tenant-B"),
                      chat.replacingOccurrences(of: "8080", with: "8081"), chat.replacingOccurrences(of: "172.31", with: "172.30")] {
            #expect(throws: StoryModelVaultError.self) { try StoryModelCatalog.url(endpoint: base, approvedLANEndpoint: wrong) }
        }

        typealias Record = StoryModelVault.Record
        let legacy = try JSONDecoder().decode(Record.self, from: Data(#"{"endpoint":"https://old.invalid/v1/chat/completions","model":"old","apiKey":"old-key"}"#.utf8))
        #expect(try legacy.validated().endpoint.absoluteString == legacy.endpoint)
        let anonymous = Record(endpoint: chat, model: "fixture", apiKey: "", approvedLANEndpoint: chat)
        let dedicated = Record(endpoint: chat, model: "fixture", apiKey: "lan-only", approvedLANEndpoint: chat)
        let revoked = Record(endpoint: chat, model: "fixture", apiKey: "lan-only", approvedLANEndpoint: nil)
        let otherChat = chat.replacingOccurrences(of: "tenant-A", with: "tenant-B")
        let other = Record(endpoint: otherChat, model: "fixture", apiKey: "other-key", approvedLANEndpoint: otherChat)
        func catalog(_ saved: Record?, key: String = "") throws -> URLRequest {
            try StoryModelCatalog.request(endpoint: base, apiKey: key, approvedLANEndpoint: chat) { saved }
        }
        for record: Record? in [nil, anonymous, legacy, other] {
            let request = try catalog(record)
            #expect(request.httpMethod == "GET" && request.url?.absoluteString == models)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(!request.allowsCellularAccess && !request.httpShouldHandleCookies)
        }
        #expect(try catalog(dedicated).value(forHTTPHeaderField: "Authorization") == "Bearer lan-only")
        #expect(try catalog(other, key: "entered").value(forHTTPHeaderField: "Authorization") == "Bearer entered")
        #expect(throws: StoryModelVaultError.self) { try catalog(revoked) }
        #expect(throws: StoryModelVaultError.self) { try catalog(nil, key: "bad\r\nkey") }
        #expect(throws: StoryModelVaultError.self) {
            try StoryModelCatalog.request(endpoint: legacy.endpoint, apiKey: "", approvedLANEndpoint: nil) { anonymous }
        }
        let lanConfig = try anonymous.validated()
        let settings = StoryModelSessionPolicy.settings(for: lanConfig.endpoint)
        #expect(!settings.allowsCellularAccess && !settings.httpShouldSetCookies)
        #expect(settings.httpCookieStorage == nil && settings.urlCredentialStorage == nil)
        #expect(settings.connectionProxyDictionary?["HTTPEnable"] as? Bool == false)
        let ids = try StoryModelCatalog.parse(Data(#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}"#.utf8))
        #expect(ids == ["a", "b"])
        #expect(throws: (any Error).self) { try StoryModelCatalog.parse(Data(#"{"data":[]}"#.utf8)) }
        let style = try StoryStyleDirector.parse(#"{"palette":"deepOrbit","atmosphere":"rainFog","typography":"classicSerif"}"#)
        #expect(style.atmosphere == "rainFog" && style.palette == "deepOrbit")
        #expect(throws: (any Error).self) { try StoryStyleDirector.parse(#"{"palette":"unknown","atmosphere":"calm","typography":"classicSerif"}"#) }
        #expect(throws: (any Error).self) { try StoryStyleDirector.parse(#"{"palette":"default","atmosphere":"calm","typography":"classicSerif","url":"unexpected"}"#) }
        let f = try EPUBLibraryFixture(); defer { f.remove() }
        let raw = #"{"temperature":0.5,"openai_max_tokens":480,"prompts":[{"identifier":"A","role":"system","content":"excluded"},{"identifier":"B","role":"user","content":" keep spaces "},{"identifier":"C","role":"system","content":"Write a novel."},{"identifier":"chatHistory","marker":true,"system_prompt":true}],"prompt_order":[{"character_id":100001,"order":[{"identifier":"C","enabled":true},{"identifier":"A","enabled":false},{"identifier":"chatHistory","enabled":true},{"identifier":"B","enabled":true}]}]}"#
        let file = f.root.appendingPathComponent("fixture.json"); try Data(raw.utf8).write(to: file)
        let preset = try await f.service.importStoryPreset(from: file)
        let book = try await f.install(f.archive()).book
        let session = try await f.service.startStory(book: book, roleKind: .original, roleName: "渡客", premise: "送信", presetID: preset.summary.id)
        let config = StoryModelConfiguration(endpoint: URL(string:"https://example.invalid/v1/chat/completions")!, model:"fixture")
        let styleDraft = StoryStyleDirector.prepare(session: session, configuration: config)
        let payloadBytes = try StoryStyleDirector.body(styleDraft)
        let json = try JSONSerialization.jsonObject(with: payloadBytes)
        let styleBody = try #require(json as? [String:Any])
        let displayed = styleDraft.messages.map { ["role": $0.role, "content": $0.content] }
        #expect(styleDraft.messages.map(\.role) == ["system", "user"])
        #expect((styleBody["messages"] as? [[String:String]]) == displayed)
        #expect(styleDraft.messages.last?.content == String(session.opening.prefix(480)))
        let lanStyle = StoryStyleDirector.prepare(session: session, configuration: lanConfig)
        let styleTarget = StoryModelConfiguration(endpoint: lanStyle.endpoint, model: lanStyle.model)
        let styleBytes = try StoryStyleDirector.body(lanStyle)
        let styleRequest = try StoryModelTransport.request(configuration: styleTarget, body: styleBytes, record: dedicated)
        #expect(styleRequest.url?.absoluteString == chat && styleRequest.httpMethod == "POST" && styleRequest.httpBody == styleBytes)
        #expect(styleRequest.value(forHTTPHeaderField: "Authorization") == "Bearer lan-only")
        let lanDraft = try await f.service.prepareStoryGeneration(session: session, expectedCount: 0, action: "听潮", configuration: lanConfig)
        let frozen = StoryModelConfiguration(endpoint: lanDraft.endpoint, model: lanDraft.model)
        let generation = try StoryModelTransport.request(configuration: frozen, body: lanDraft.body, record: anonymous)
        #expect(generation.url?.absoluteString == chat && generation.httpMethod == "POST" && generation.httpBody == lanDraft.body)
        #expect(generation.value(forHTTPHeaderField: "Authorization") == nil && !generation.allowsCellularAccess)
        let renamed = Record(endpoint: chat, model: "changed", apiKey: "", approvedLANEndpoint: chat)
        let misbound = Record(endpoint: chat, model: "fixture", apiKey: "", approvedLANEndpoint: otherChat)
        for stale: Record? in [nil, revoked, other, renamed, misbound] {
            #expect(throws: StoryModelVaultError.self) {
                try StoryModelTransport.request(configuration: frozen, body: lanDraft.body, record: stale)
            }
        }
        let one = try await f.service.prepareStoryGeneration(session: session, expectedCount: 0, action: "听潮", configuration: config)
        #expect(one.messages.map(\.role) == ["system","user","user","user"])
        #expect(one.messages.first?.content == "Write a novel." && one.messages.last?.content == " keep spaces ")
        #expect(!one.messages.contains { $0.content == "excluded" })
        #expect(one.messages[1].content.contains(session.opening) && one.messages[1].content.contains(session.roleName))
        let bookTurn = try await f.service.runConfirmedStoryGeneration(one) { target, body in
            let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(target.endpoint == one.endpoint && payload["model"] as? String == one.model)
            #expect(payload["temperature"] as? Double == 0.5 && payload["max_tokens"] as? Int == 480)
            let sent = try JSONDecoder().decode([String: [StoryModelMessage]].self, from: JSONSerialization.data(withJSONObject: ["messages":payload["messages"]!]))
            #expect(sent["messages"] == one.messages)
            return "船终于靠岸。"
        }
        #expect(bookTurn.modelName == "fixture")
        await #expect(throws: StoryTurnError.self) {
            try await f.service.runConfirmedStoryGeneration(one) { _,_ in Issue.record("Stale draft reached transport"); return "unexpected" }
        }
        let next = try await f.service.prepareStoryGeneration(session: session, expectedCount: 1, action: "下船", configuration: config)
        #expect(next.messages.filter { $0.role == "assistant" && $0.content == bookTurn.narration }.count == 1)
        await #expect(throws: CancellationError.self) {
            try await f.service.runConfirmedStoryGeneration(next) { _,_ in throw CancellationError() }
        }
        await #expect(throws: StoryGenerationError.self) {
            try await f.service.runConfirmedStoryGeneration(next) { _,_ in return " \n" }
        }
        let reopened = try LibraryStore(root: f.managed)
        #expect(try await reopened.storyTurns(sessionID: session.id) == [bookTurn])
    }
}
