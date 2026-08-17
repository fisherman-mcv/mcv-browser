import XCTest
import WebKit
@testable import MCV

final class NativeAdblockTests: XCTestCase {
    func testNativeRulesCompileInWebKit() throws {
        let json = try XCTUnwrap(SecurityManager.nativeRuleJSON())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThan(rules.count, 80)

        let compiled = expectation(description: "WKContentRuleList compilation")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mcv-native-shield-test",
            encodedContentRuleList: json
        ) { list, error in
            XCTAssertNil(error)
            XCTAssertNotNil(list)
            compiled.fulfill()
        }
        wait(for: [compiled], timeout: 10)
    }
}
