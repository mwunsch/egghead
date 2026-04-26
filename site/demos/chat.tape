# §2 — Chat mode: shared transcript, nick-prefixed, /pass on empty
#
# Renders to site/static/assets/demos/chat.{mp4,gif}
# Assumes a curated demo store with 2–3 agents, at least one likely to
# /pass on a huddle. See site/demos/README.md

Output ../static/assets/demos/chat.mp4
Output ../static/assets/demos/chat.gif

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
Type "/chat"
Enter
Show

Sleep 1500ms
Type@70ms "If there's one thing you want people to know about Egghead what is it?"
Sleep 800ms
Enter

# Streaming flushes on \n\n, so timing here is generous. Tune after
# watching a take — real LLM latency varies.
Sleep 90s

Hide
Ctrl+q
