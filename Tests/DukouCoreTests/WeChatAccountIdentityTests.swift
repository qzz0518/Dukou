import XCTest
@testable import DukouCore

final class WeChatAccountIdentityTests: XCTestCase {
    private typealias Field = WeChatAccountIdentity.Field
    private func account(_ name: String, heading: String = "账号", logout: String = "退出登录") -> [Field] {
        [.init(role: "AXStaticText", text: heading), .init(role: "AXButton", text: ""),
         .init(role: "AXStaticText", text: name), .init(role: "AXStaticText", text: "wxid_example"),
         .init(role: "AXButton", text: logout)]
    }

    func testReadsOnlyNicknameFromTheObservedAccountSection() {
        let before = [Field(role: "AXButton", text: "账号与存储"), .init(role: "AXButton", text: "通用")]
        let after = [Field(role: "AXStaticText", text: "登录方式"), .init(role: "AXStaticText", text: "其他人的昵称")]
        XCTAssertEqual(WeChatAccountIdentity.nickname(in: before + account("我的昵称") + after), "我的昵称")
        XCTAssertEqual(WeChatAccountIdentity.nickname(in: account(" Alice & Bob <你好> ")), " Alice & Bob <你好> ")
        XCTAssertEqual(WeChatAccountIdentity.nickname(in: account("账号")), "账号")
        XCTAssertEqual(WeChatAccountIdentity.nickname(in: account("Log Out", heading: "Account", logout: "Log Out")), "Log Out")
    }

    func testDoesNotGuessFromContactsMessagesOrIncompleteAccountInformation() {
        for fields in [[], [Field(role: "AXStaticText", text: "我是自己")], Array(account("本人").dropLast()),
                       account("本人") + account("另一个账号"), account(" "), account("名\n字")] {
            XCTAssertNil(WeChatAccountIdentity.nickname(in: fields))
        }
        let combined = [Field(role: "AXStaticText", text: "账号"), .init(role: "AXButton", text: ""),
                        .init(role: "AXStaticText", text: "昵称 wxid_example"), .init(role: "AXButton", text: "退出登录")]
        XCTAssertNil(WeChatAccountIdentity.nickname(in: combined), "Do not split a display name at a guessed whitespace boundary")
    }

    func testUnknownLayoutOrAccountIDDoesNotReturnAnotherSettingAsTheNickname() {
        var fields = account("本人")
        fields[3] = .init(role: "AXStaticText", text: "")
        XCTAssertNil(WeChatAccountIdentity.nickname(in: fields))
        fields[3] = .init(role: "AXStaticText", text: "not an account field")
        XCTAssertNil(WeChatAccountIdentity.nickname(in: fields))
        fields = account("本人")
        fields.insert(.init(role: "AXStaticText", text: "新增设置"), at: 2)
        XCTAssertNil(WeChatAccountIdentity.nickname(in: fields))
        fields = account("本人")
        fields[4] = .init(role: "AXStaticText", text: "退出登录")
        XCTAssertNil(WeChatAccountIdentity.nickname(in: fields))
    }
}
