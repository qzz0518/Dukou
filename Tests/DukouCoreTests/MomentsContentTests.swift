import Foundation
import Testing
@testable import DukouCore

struct MomentsContentTests {
    @Test func recognizesNativeAdvertisementPopover() {
        // Native AX controls observed on the LibTV ad; row text has no ad flag.
        #expect(MomentsAdvertisementMenu.matches(
            staticTexts: ["赞助商提供的广告信息", "你觉的这条广告怎么样？", "还不错", "关闭该广告", "投诉"],
            buttonLabels: ["还不错", "关闭该广告"]
        ))
    }

    @Test func advertisementDetectionRequiresBothControlsAndTheirRoles() {
        let notice = "赞助商提供的广告信息"
        let close = "关闭该广告"
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: [notice, close], buttonLabels: []))
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: [], buttonLabels: [notice, close]))
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: [notice], buttonLabels: ["投诉"]))
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: [], buttonLabels: [close]))
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: ["小明 \(notice) \(close) 昨天"], buttonLabels: [close]))
        #expect(!MomentsAdvertisementMenu.matches(staticTexts: ["广告", "推广", "LibTV-official"], buttonLabels: ["更多"]))
    }

    @Test func preservesSpacedAuthorAndFullBody() throws {
        let content = try #require(MomentsContent.parse("Future Shine 第一段\n\n完整长文 包含4张图片 东京 6小时前 ", author: "Future Shine"))
        #expect(content.text == "第一段\n\n完整长文 包含4张图片 东京")
        #expect(content.timestamp == "6小时前")
        #expect(content.imageCount == 4)
        #expect(!content.isVideo)
        #expect(MomentsContent.parse("Alice 正文 1小时前 ", author: "Bob") == nil)
    }

    @Test func supportsMediaOnlyAndVideo() throws {
        let image = try #require(MomentsContent.parse("小明 包含9张图片 昨天 ", author: "小明"))
        #expect(image.text == "包含9张图片")
        #expect(image.imageCount == 9)
        let video = try #require(MomentsContent.parse("小径湾 Elmo 今日天晴 视频 3小时前 ", author: "小径湾 Elmo"))
        #expect(video.isVideo)
        #expect(video.text == "今日天晴 视频")
        let link = try #require(MomentsContent.parse("Future Shine 署前街少年 - 赵雷 9分钟前 酷狗音乐 ", author: "Future Shine"))
        #expect(link.text == "署前街少年 - 赵雷\n酷狗音乐")
    }

    @Test func relativeTimeDoesNotChangeIdentity() {
        #expect(MomentsContent.identity("小明 2小时前我到家了 包含1张图片 59分钟前 ") == MomentsContent.identity("小明 2小时前我到家了 包含1张图片 1小时前 "))
    }

    @Test func mediaWordsNeverRemoveAuthorText() throws {
        let content = try #require(MomentsContent.parse("小明 这篇文章 包含3张图片，并讨论 视频 教程。 1小时前 ", author: "小明"))
        #expect(content.text == "这篇文章 包含3张图片，并讨论 视频 教程。")
    }

    @Test func sharedExpressionsKeepConcurrentParsesAndIdentitiesIndependent() async {
        let examples: [(label: String, author: String, content: MomentsContent, identity: String)] = [
            (
                "Orbit Pilot FIRST 2 HOURS AGO Contains 1 photo then CONTAINS 3 PHOTOS VIDEO Yesterday 09:04 Synthetic App ",
                "Orbit Pilot",
                MomentsContent(text: "FIRST 2 HOURS AGO Contains 1 photo then CONTAINS 3 PHOTOS VIDEO\nSynthetic App", timestamp: "Yesterday 09:04", imageCount: 3, isVideo: false),
                "Orbit Pilot FIRST 2 HOURS AGO Contains 1 photo then CONTAINS 3 PHOTOS VIDEO  Synthetic App "
            ),
            (
                "星舟 👩‍🚀 e\u{301} 视频 刚刚 ",
                "星舟 👩‍🚀",
                MomentsContent(text: "e\u{301} 视频", timestamp: "刚刚", imageCount: 0, isVideo: true),
                "星舟 👩‍🚀 e\u{301} 视频  "
            ),
            (
                "Orbit Pilot A ViDeO 8 MINUTES AGO ",
                "Orbit Pilot",
                MomentsContent(text: "A ViDeO", timestamp: "8 MINUTES AGO", imageCount: 0, isVideo: true),
                "Orbit Pilot A ViDeO  "
            ),
            (
                "Orbit Pilot Plain text without a timestamp",
                "Orbit Pilot",
                MomentsContent(text: "Plain text without a timestamp", timestamp: "", imageCount: 0, isVideo: false),
                "Orbit Pilot Plain text without a timestamp"
            ),
        ]
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    examples.allSatisfy { example in
                        MomentsContent.parse(example.label, author: example.author) == example.content &&
                        MomentsContent.identity(example.label) == example.identity
                    }
                }
            }
            for await matches in group { #expect(matches) }
        }
    }

    @Test func acceptsPositiveCountsAndEnforcesFolderMode() throws {
        var preset = MomentsForwardPreset()
        for count in [1, 100, 101, 1_000, Int.max] {
            preset.count = count
            #expect(preset.isValid)
            #expect(MomentsForwardPreset.decode(try JSONEncoder().encode(preset)).count == count)
        }
        for count in [0, -1] {
            preset.count = count
            #expect(!preset.isValid)
        }
        preset.destinationFolder = URL(fileURLWithPath: "/tmp/export")
        preset.pastePath = true
        let decoded = MomentsForwardPreset.decode(try JSONEncoder().encode(preset))
        #expect(decoded.isValid)
        #expect(!decoded.pastePath)
        #expect(decoded.destinationFolder == preset.destinationFolder)
    }
}
