# §1 — Records mode: Notational Velocity for your second brain
#
# Renders to site/static/assets/demos/records.{mp4,gif}
# Assumes a curated demo store — see site/demos/README.md

Output ../static/assets/demos/records.mp4
Output ../static/assets/demos/records.gif

Set Shell "zsh"
Set FontSize 16
Set Width 960
Set Height 1200
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0
Set Padding 20

Hide
Type "../../bin/egghead"
Enter
Wait+Screen@30s /records/
Show

# Type-to-filter — pick a recognizable subject from the demo store
Sleep 1500ms
Type@80ms "research/"
Sleep 1500ms

# Arrow down through results; let the preview settle between jumps
Down
Sleep 700ms
Down
Sleep 2s

# Tab through wikilinks in the preview pane
Ctrl+N
Sleep 1200ms
Ctrl+N
Sleep 1200ms
Tab
Sleep 700ms
Tab
Sleep 1000ms
Enter
Sleep 1500ms
Ctrl+N
Sleep 2s

# Clear search
Ctrl+A
Sleep 500ms
Ctrl+K
Sleep 3500ms
Hide

Ctrl+Q
