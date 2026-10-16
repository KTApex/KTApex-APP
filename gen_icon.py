"""Generate the MyVault 1024x1024 app icon: deep navy gradient + gold vault lock."""
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S))
px = img.load()

# Diagonal deep-navy gradient: #081226 -> #16305B
c0 = (8, 18, 38)
c1 = (22, 48, 91)
for y in range(S):
    for x in range(0, S, 4):
        t = (x + y) / (2 * S)
        col = (
            int(c0[0] + (c1[0] - c0[0]) * t),
            int(c0[1] + (c1[1] - c0[1]) * t),
            int(c0[2] + (c1[2] - c0[2]) * t),
        )
        for dx in range(4):
            if x + dx < S:
                px[x + dx, y] = col

# Soft radial glow, top-left
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([-350, -350, 750, 750], fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(220))
img = Image.composite(Image.new("RGB", (S, S), (60, 100, 165)), img, glow)

draw = ImageDraw.Draw(img)
GOLD = (232, 194, 90)
GOLD_DARK = (196, 158, 60)
NAVY = (10, 22, 42)

# Thin gold ring (vault motif)
draw.ellipse([152, 152, 872, 872], outline=GOLD_DARK, width=10)

# Lock body (rounded rect)
draw.rounded_rectangle([352, 470, 672, 730], radius=44, fill=GOLD)
# Inner shading strip at bottom of body
draw.rounded_rectangle([352, 640, 672, 730], radius=44, fill=GOLD_DARK)
draw.rectangle([352, 640, 672, 690], fill=GOLD_DARK)

# Shackle
draw.arc([416, 340, 608, 560], start=180, end=360, fill=GOLD, width=48)

# Keyhole
draw.ellipse([486, 556, 538, 608], fill=NAVY)
draw.rounded_rectangle([502, 590, 522, 646], radius=9, fill=NAVY)

img.save("MyVault/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", "PNG")
print("saved", img.size)
