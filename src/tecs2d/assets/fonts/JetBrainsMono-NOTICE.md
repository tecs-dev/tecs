# JetBrains Mono

`jetbrainsmono-extrabold-msdf.json` and
`jetbrainsmono-extrabold-msdf.png` are an MSDF atlas derived from
JetBrains Mono ExtraBold 2.304.

- Source: <https://github.com/JetBrains/JetBrainsMono/tree/v2.304>
- Source font:
  `fonts/ttf/JetBrainsMono-ExtraBold.ttf`
- Source SHA-256:
  `8e501d3a6a883e83ea4f7852804fb0894cebdd67751bb1006b37a476cef34cd6`
- Generator: `msdf-bmfont-xml` 2.8.0
- Characters: printable ASCII (`U+0020` through `U+007E`)

The atlas was generated with:

```bash
npx --yes msdf-bmfont-xml@2.8.0 \
    -f json \
    -o jetbrainsmono-extrabold-msdf.png \
    -s 64 \
    -m 512,512 \
    -r 8 \
    --pot \
    --square \
    JetBrainsMono-ExtraBold.ttf
```

The atlas is Font Software distributed under the SIL Open Font License 1.1.
See `JetBrainsMono-OFL.txt`.
