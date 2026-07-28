# Social card templates

The HTML sources for the project's social media images: the GitHub repo
social preview (1280x640) and the itch.io cover (630x500). Edit the HTML,
re-render, upload. Both were designed against the fonts on a Fedora desktop
(Cantarell for the headings); anything with a bold geometric sans will do.

Render with any Chromium-family browser:

```sh
cd godot/tools/social_cards
brave-browser --headless=new --disable-gpu --window-size=1280,640 \
    --screenshot=github.png  "file://$PWD/card_github.html"
brave-browser --headless=new --disable-gpu --window-size=630,500 \
    --screenshot=itch.png    "file://$PWD/card_itch.html"
```

Upload targets: GitHub repo Settings -> General -> Social preview;
itch.io Edit game -> cover image.

Assets:

- `social_bg.jpg` -- a frame of the Huge Pyramid mid-collapse, extracted at
  2.2 s from a 1080p60 capture of the demo (bombed with Blast 300). Any
  replacement backdrop should be 1920x1080; the templates oversize and pan
  it, so reframing means adjusting `background-size` / `background-position`.
- `godot_icon.svg` -- the official Godot engine icon, from the engine
  repository (`icon.svg`). Godot logo (c) Andrea Calabró, CC-BY 4.0.
