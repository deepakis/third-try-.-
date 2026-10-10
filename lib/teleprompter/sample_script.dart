/// Demo script: a tech reviewer talking to camera while the prompter cuts OBS
/// for them. The bracketed tags are invisible to the presenter's intent — they
/// look like stage directions because that's exactly what they are.
const String demoScript = '''
Welcome back to the channel. Today I'm wiring up a two-camera rig that cuts itself — no editor, no second operator, no Stream Deck.
[CAM 1]
Right now you're on camera one: full-screen talking head, which is where I'll live for most of this video.
Everything you see behind me is one OBS scene. Watch what happens when this line hits the red mark.
[LAYOUT: PIP]
And there's the cut. Camera two is my screen capture, and my face dropped into the corner so you can still see me react.
[LAYOUT: PIP]
This is the shot I'll be in whenever I'm walking through code, a slide deck, or a settings menu you shouldn't have to pause to read.
[CAM 2: ZOOM]
Same layout, tighter framing — useful when the thing on screen is small and you'd otherwise be squinting at a settings dialog.
[CAM 1]
Back to the face. Notice the audio never ducked, the cut never stuttered, and I never touched a keyboard.
[LAYOUT: FULL]
That's the whole trick: the prompter knows where the visuals should change, because the script says so.
[LAYOUT: PIP]
If you want the setup for this, the second video walks through the scene layout and the cue tags one at a time.
[CAM 1]
Hit subscribe if that's useful, and I'll see you in the next one.
''';
