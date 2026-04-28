Output ../static/assets/demos/capability.mp4

Set Shell "zsh"
Set FontSize 17
Set Width 960
Set Height 1200
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0
Set Padding 20

Hide
Type "cd ../../bin && clear"
Enter
Show

Type "./egghead agents capabilities agents/platypus"
Enter
Sleep 1500ms
Type "./egghead agents grant agents/platypus"
Enter
Wait+Screen@1000ms /Capability:/
Sleep 800ms
Down@450ms 4
Enter
Wait+Screen@1000ms /Paths/
Sleep 800ms
Type "~/Documents"
Enter
Wait+Screen@500ms /y\/N/
Sleep 1s
Type "y"
Sleep 600ms
Enter
Sleep 1400ms
