# 插画说明

沿用 [zelong.vip](https://zelong.vip) 的自有人物与橘猫
暖纸底、细黑墨线、少量朱橙；插画解释工作方式，不是产品截图
工具：OpenAI 内置 image_gen，未使用 CLI/API fallback
参考：作者网站的睡眠协作插画与现有带字项目封面

- `art/copybridge-desk.webp`：README 场景主图，保留同名 PNG 源图
- `art/copybridge-flow.svg`：可编辑流程图，文字保留为向量文本
- `art/copybridge-card.webp`：网站配图的静态版，旁白直接画在图内

## README 场景提示词

```text
Use case: illustration-story. Transform the supplied self-owned Zelong illustration into a new CopyBridge scene while preserving the exact recurring character identity, pencil-and-ink rendering and warm ivory paper palette (#f1eee4), charcoal #171612 outlines, sparse vermilion #d65336 accents. Young East Asian adult man, short tousled black hair, round thin glasses, cream white T-shirt. This is a story illustration, not a screenshot. No neon, no gradients, no plastic 3D, no photorealism. No text, no labels, no logos, no watermark. Two personal computers communicate directly; absolutely NO cloud, server, intermediary machine or internet globe. Landscape 3:2. Wide continuous desk scene: the man on left at an open slim laptop presses its keyboard, a desktop monitor and keyboard sit on right. Both screens show the SAME small document symbol and picture symbol, connected by a thin loose vermilion line across the table as an illustration of clipboard transfer. The original orange-white kitten with red collar and round gold T tag plays gently with this line in the center foreground, full body visible. Make both computers prominent, faces and paws natural and recognizable. Leave airy unmarked paper above the desk for a calm editorial feeling. Preserve full silhouettes.
```

## 网站双帧提示词

```text
Edit these two supplied self-owned illustrations into ONE TWO-FRAME HORIZONTAL SPRITE SHEET for the CopyBridge project card. Reference1 is the current website's EXACT typography and scene style; reference2 supplies CopyBridge's two computers and same character/cat. Output aspect ratio 3:1, ideally1536x512, comprising TWO equal 3:2 panels side by side with no gutter or border. Each panel shows the SAME composition and fixed lettering. Warm ivory paper, fine charcoal ink and pencil, restrained orange-red accents, young Chinese man with black tousled hair, round glasses, white T-shirt, orange-white kitten red collar gold T tag. In EACH panel, left 32% contains large beautiful black handwritten Chinese text EXACTLY three lines: '在 Mac 复制' then '到 Windows 粘贴' then '两台电脑直接同步'. Center-right is man typing on a slim laptop, orange-white kitten between laptop and desktop monitor. Same document/picture icons on the two computers, thin orange line connects them directly, NO server, NO cloud. Full heads/paws visible. Frame1: kitten rests front paws on cable; document just outlined on target screen. Frame2: only kitten raises one paw a little and orange check appears beside target document; all other objects, camera, text positions, paper background, character pose remain completely fixed. Match the existing website reference closely including handlettered narrative and character linework. No HTML frames, no neon, no extra captions, no watermark, no third panel.
```
