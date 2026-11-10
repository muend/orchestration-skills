---
name: codex-image
description: "Generate or edit raster images (illustrations, photos, icons, logos, mockups, posters, UI art, textures, sprites, product shots, diagrams-as-art) by delegating to Codex's image generation tool via gpt-6.1-sol. Claude cannot generate images itself, so load this whenever the user asks to create, draw, render, generate, redesign, retouch or vary an image, or a project needs image assets. Teaches the detailed art-direction brief Codex follows literally, the edit/iteration loop, and verification. Uses the codex skill's script."
---

# Image generation through Codex

Claude writes the art direction; **gpt-6.1-sol** executes it literally with its built-in image tool.
The brief is the whole quality ceiling: Sol will not invent missing details well, and it will not
"use judgment" on open questions. Decide everything first, then write it down.

## Engine and role profiles

Images come from Codex's **built-in `image_gen` tool on the ChatGPT Pro sign-in — no API, no per-image
fees.** That tool takes only a prompt, reference images and `transparent_background`; the server picks
the image model, so specific models (GPT Image 2.6 Sunburst / Flare, etc.) **cannot be selected** here.
Never switch to an API key or Codex's image CLI fallback.

Role-specific control comes from **profiles** in `~/.claude/skills/codex/image-profiles.json`, passed with
`-ImageProfile <name>`. A profile appends role style notes to the brief and can force transparency:

| Profile | Use for | Notes |
|---|---|---|
| `default` | anything else | brief only |
| `photoreal` | product shots, hero banners, editorial photos | photographic realism rules |
| `illustration` | marketing/blog/onboarding art | cohesive illustration rules |
| `icon` | app/UI icons, marks, stickers, sprites | **transparent**, padding, 32px legibility |
| `ui-asset` | mockups, dashboard visuals, empty states | crisp geometry, no fake micro-text |
| `text-heavy` | posters, covers, infographics | exact typography first |

`-Transparent` works with any profile. Add new roles by adding an entry (`transparent`, `roles`,
`style_notes`) to the JSON. The brief is still the main quality lever: profiles add, never replace it.

## Workflow

1. **Clarify only what truly blocks you** (purpose, where it will be used, size/aspect, text on image,
   brand colors). Otherwise pick sensible defaults and state them in the brief.
2. **Write the brief** to a file in the scratchpad (e.g. `brief-hero.md`) using the template below.
   Fill every section; write "none" rather than leaving a section out.
3. **Run:**
   ```
   pwsh -NoProfile -File "$HOME\.claude\skills\codex\scripts\codex.ps1" -Mode image `
     -PromptFile <brief.md> -Out <project>\assets\<name>.png [-ImageProfile icon] [-Transparent] `
     [-Count 3] [-Images ref1.png,ref2.png]
   ```
   Use `timeout: 600000`. Several different images → one background run per image (a fleet).
4. **Verify yourself:** Read each `CODEX_IMAGE=` file and check it against the acceptance checklist.
   Codex's self-check is a claim, not proof.
5. **Iterate** with `-Session <CODEX_THREAD_ID>` and a short delta brief ("Keep everything; change only:
   ..."), or do a targeted edit by passing the previous output with `-Images` and an edit brief.
6. **Deliver:** show the image to the user (Read it / SendUserFile), give the path, and mention the
   thread id is available for further iterations.

## Brief template (copy, fill every field)

```markdown
# Purpose & usage
<what this image is for, where it appears (hero banner, app icon, slide, print), audience>

# Output
- Aspect ratio / size: <e.g. 16:9 landscape, 1:1 square, 9:16 vertical; target px if known>
- Format/background: <opaque | transparent background | solid #FFFFFF>
- Variants: <1 | N, and how variants should differ>

# Subject
<main subject(s) in concrete terms: who/what, count, pose, expression, action, clothing/material,
age/ethnicity only if relevant and specified by the user>

# Composition & camera
- Framing: <close-up | medium | wide | top-down | isometric | flat orthographic>
- Placement: <subject position (rule of thirds, centered), negative space for text on which side>
- Camera/lens (photo styles): <e.g. 50mm, f/2.8 shallow depth of field, eye level>
- Foreground / midground / background: <each described>

# Style
- Medium: <photoreal | 3D render | flat vector | line art | watercolor | pixel art | clay | isometric ...>
- References in words: <era, movement, texture, line weight, level of detail> (no living-artist names)
- Rendering detail: <minimal shapes | moderate | highly detailed>

# Color & light
- Palette: <hex codes with roles, e.g. primary #1E6FFF, accent #FFC233, background #F5F5F7>
- Lighting: <soft daylight from left | studio three-point | golden hour | neon rim light>
- Mood: <calm, energetic, premium, playful ...>

# Text in image
<"none" OR each string verbatim in quotes, with font feel (bold geometric sans), color, position, size
relative to image. Keep strings short; exact spelling and case matter.>

# Must include
- <non-negotiable elements>

# Must NOT include
- <watermarks, extra text, extra fingers, logos of real brands, clutter, specific colors ...>

# Edit instructions (only when editing an attached image)
- Image 1 is: <the image to edit | a style reference | a subject reference>
- Change: <exactly what>
- Preserve: <everything else that must stay identical: layout, faces, colors, text>

# Acceptance checklist
- [ ] <objective checks Claude will verify: aspect ratio, subject present, text exact, palette, no X>
```

## Craft notes for strong results

- Concrete nouns and measurable attributes beat adjectives ("three ceramic mugs, matte sage green
  #9CAF88, on a walnut table" ≫ "nice cozy mugs").
- One clear focal point; say where the empty space goes if text will be overlaid later.
- For icons/logos: flat, few colors, centered, generous padding, no text unless asked, test at small size.
- For UI/marketing assets: specify the exact copy, and keep text in the image minimal — real UI text is
  better added in code.
- For series/sets (sprites, icon packs, storyboard): write a shared "style bible" section and reuse it
  verbatim in each lane's brief so the set stays consistent; generate one hero first, approve it, then
  pass it with `-Images` as the style reference for the rest.
- Do not request real people's likenesses, copyrighted characters, or real brand logos.
