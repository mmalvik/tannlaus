# Icon sources

Vector masters for the icons in `Resources/`. The build doesn't use these files; edit them here, export, and commit the exported files.

| Source | Exported to | Sizes |
|---|---|---|
| `AppIcon.svg` | `Resources/AppIcon.icns` | 128–1024 px |
| `AppIcon-small.svg` (no stars, bolder Bluetooth mark) | `Resources/AppIcon.icns` | 32 and 64 px |
| `AppIcon-tiny.svg` (tooth only) | `Resources/AppIcon.icns` | 16 px |
| `MenuBarIcon.svg` | `Resources/MenuBarIcon.png`, `@2x` | 18 and 36 px |
| `MenuBarIcon-denied.svg` | `Resources/MenuBarIcon-denied.png`, `@2x` | 18 and 36 px |

The menu bar icons are template images: black on transparent only, so macOS can recolour them for light and dark menu bars.

## Exporting

Any SVG renderer that supports blur filters works. With [resvg](https://github.com/linebender/resvg) and the built-in `iconutil`:

```
mkdir -p AppIcon.iconset
for s in 128 256 512; do
  resvg -w $s AppIcon.svg AppIcon.iconset/icon_${s}x${s}.png
  resvg -w $((s * 2)) AppIcon.svg AppIcon.iconset/icon_${s}x${s}@2x.png
done
resvg -w 16 AppIcon-tiny.svg AppIcon.iconset/icon_16x16.png
resvg -w 32 AppIcon-small.svg AppIcon.iconset/icon_16x16@2x.png
resvg -w 32 AppIcon-small.svg AppIcon.iconset/icon_32x32.png
resvg -w 64 AppIcon-small.svg AppIcon.iconset/icon_32x32@2x.png
iconutil -c icns AppIcon.iconset -o ../../Resources/AppIcon.icns
rm -r AppIcon.iconset

for n in MenuBarIcon MenuBarIcon-denied; do
  resvg -w 18 $n.svg ../../Resources/$n.png
  resvg -w 36 $n.svg ../../Resources/$n@2x.png
done
```
