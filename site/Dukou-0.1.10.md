<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **朋友圈里的广告不再让整轮导出失败**。广告帖没有正常的作者，Dukou 读到它就会按「读不到作者就停下、不猜」的规则中断——那条规则对加载失败的帖子是对的，对本来就没有作者的广告则不然，结果是范围内只要有一条广告就一条都导不出来。现在遇到广告会跳过它继续往下读。广告标记在辅助功能树里根本不存在，所以判断依据是它自己的弹窗：必须同时有「赞助商提供的广告信息」这段说明和「关闭该广告」这个按钮，才算广告——只是正文里提到广告的帖子不会被误删。探测在点头像之前进行（广告的头像会跳去广告主网站），弹窗一律用 ESC 关掉，绝不会去点「关闭该广告」，那会把广告从你自己的朋友圈里移除。

## Changelog

1. **A sponsored post no longer ends the whole export.** An ad has no author the way an ordinary post does, so reading one raised the author error — the deliberate refusal to guess, which is right for a post whose author failed to load and wrong for one that never had an author. A single ad anywhere in the requested range meant nothing was exported. Ads are now skipped and the run continues. The ad badge is absent from the accessibility tree, so the evidence is the ad's own popover: both the 赞助商提供的广告信息 notice and the 关闭该广告 button must be present, in those roles, before anything is treated as an ad — a post that merely mentions ads is not dropped from your export. The probe happens before the avatar is touched, since an ad's avatar navigates to the advertiser's site, and the popover is always dismissed with Esc, never by pressing 关闭该广告, which would remove the ad from your own feed.
